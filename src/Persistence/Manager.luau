--!strict
local Value = require("./Value")
local Schema = require("./Schema")
local Journal = require("../Utility/Journal")
local EngineAdapter = require("../Roblox/DataStore")
local Environment = require("../Roblox/Environment")
export type StoreOptions = {
	Defaults: { [string]: any },
	Schema: ((any) -> (boolean, string?))?,
	RenamedFrom: { [string]: string }?,
	AutosaveInterval: number?,
	SessionTimeout: number?,
}
export type Options = {
	Stores: { [string]: StoreOptions }?,
	Adapter: any?,
	Clock: (() -> number)?,
	WallClock: (() -> number)?,
	Wait: ((number) -> ())?,
	Spawn: ((() -> ()) -> any)?,
	Random: (() -> number)?,
	NewToken: (() -> string)?,
	RequestTimeout: number?,
	RetryAttempts: number?,
	ShutdownTimeout: number?,
	HistoryLimit: number?,
	Logger: any?,
	Pulse: any?,
	PlayerSource: any?,
}
local Manager = {}
Manager.__index = Manager
local Store = {}
Store.__index = Store
local Session = {}
Session.__index = Session
local sequence = 0
local function positive(value: any, name: string): number
	assert(type(value) == "number" and value > 0 and value < math.huge, `{name} must be positive and finite`)
	return value
end
local function event(manager: any, state: string, store: string, key: string, reason: string?)
	manager._history:Push({ State = state, Store = store, Key = key, Reason = reason })
	if manager._logger then
		pcall(function()
			local method = if reason then "Warn" else "Debug"
			manager._logger[method](
				manager._logger,
				"Persistence " .. state,
				{ Store = store, Key = key, Reason = reason }
			)
		end)
	end
end
local function record(value: any): any
	assert(
		type(value) == "table" and value.Format == 1 and type(value.Data) == "table",
		"Unsupported or corrupt persistence record"
	)
	assert(
		type(value.Revision) == "number"
			and value.Revision >= 1
			and value.Revision < math.huge
			and value.Revision % 1 == 0,
		"Invalid record revision"
	)
	assert(
		type(value.Schema) == "table"
			and type(value.Schema.Revision) == "number"
			and value.Schema.Revision >= 1
			and value.Schema.Revision < math.huge
			and value.Schema.Revision % 1 == 0,
		"Invalid record schema"
	)
	if value.Lock ~= nil then
		assert(
			type(value.Lock) == "table" and type(value.Lock.Owner) == "string" and type(value.Lock.Expires) == "number",
			"Invalid session lock"
		)
	end
	return value
end
function Manager.new(supplied: Options?): any
	local options: Options = supplied or {}
	local engine = Environment.Persistence()
	local adapter = options.Adapter or EngineAdapter.new()
	assert(type(adapter.Update) == "function", "Persistence Adapter requires Update")
	sequence += 1
	local self: any = setmetatable({
		_adapter = adapter,
		_stores = {},
		_sessions = {},
		_loads = {},
		_busy = {},
		_stopping = false,
		_destroyed = false,
		_ticking = false,
		_connection = nil,
		_clock = options.Clock or os.clock,
		_wall = options.WallClock or os.time,
		_wait = options.Wait or (engine and engine.Wait),
		_spawn = options.Spawn or (engine and engine.Spawn),
		_random = options.Random or math.random,
		_newToken = options.NewToken,
		_sequence = 0,
		_prefix = tostring(sequence),
		_timeout = positive(options.RequestTimeout or 10, "RequestTimeout"),
		_attempts = positive(options.RetryAttempts or 5, "RetryAttempts"),
		_shutdown = positive(options.ShutdownTimeout or 25, "ShutdownTimeout"),
		_history = Journal.new(options.HistoryLimit or 128),
		_logger = options.Logger,
		_playerConnection = nil,
	}, Manager)
	assert(self._attempts % 1 == 0 and self._attempts <= 20, "RetryAttempts must be an integer up to 20")
	for name, config in options.Stores or {} do
		assert(type(name) == "string" and #name > 0 and #name <= 50, "Invalid persistence store name")
		local interval = positive(config.AutosaveInterval or 60, "AutosaveInterval")
		local ttl = positive(config.SessionTimeout or 180, "SessionTimeout")
		assert(ttl > interval * 2 + self._timeout, "SessionTimeout must exceed two save intervals and RequestTimeout")
		self._stores[name] = setmetatable({
			_manager = self,
			_name = name,
			_schema = Schema.new(config),
			_interval = interval,
			_ttl = ttl,
		}, Store)
	end
	local pulse = options.Pulse or (engine and engine.Pulse)
	if pulse then
		assert(self._spawn and self._wait, "Persistence pulse requires Spawn and Wait")
		self._connection = pulse:Connect(function()
			if self._ticking or self._stopping then
				return
			end
			self._ticking = true
			(self._spawn :: any)(function()
				local ok, reason = pcall(function()
					self:Step()
				end)
				self._ticking = false
				if not ok then
					event(self, "TickFailed", "", "", tostring(reason))
				end
			end)
		end)
	end
	local players = options.PlayerSource or (engine and engine.Players)
	if players then
		assert(self._spawn, "Automatic player release requires Spawn")
		self._playerConnection = players.PlayerRemoving:Connect(function(player: any)
			for _, session in table.clone(self._sessions) do
				if session._userId == player.UserId then
					(self._spawn :: any)(function()
						session:Release()
					end)
				end
			end
		end)
		self._players = players
	end
	return self
end
function Manager._token(self: any): string
	if self._newToken then
		return (self._newToken :: any)()
	end
	if self._adapter.NewToken then
		return self._adapter:NewToken()
	end
	self._sequence += 1
	return `{self._prefix}:{self._sequence}`
end
local function pause(self: any, seconds: number): (boolean, string?)
	if not self._wait then
		return false, "Persistence retry requires a Wait port"
	end
	local ok, reason = pcall(self._wait, seconds)
	return ok, if ok then nil else tostring(reason)
end
-- One ordered request per key. Other keys can save concurrently.
function Manager._exclusive(self: any, id: string, callback: any): (boolean, any)
	local deadline = self._clock() + self._timeout
	while self._busy[id] do
		if self._clock() >= deadline then
			return false, "Persistence key is busy"
		end
		local ok, reason = pause(self, math.min(0.05, deadline - self._clock()))
		if not ok then
			return false, reason
		end
	end
	self._busy[id] = true
	local ok, result, reason = pcall(callback)
	self._busy[id] = nil
	if not ok then
		return false, tostring(result)
	end
	return result, reason
end
function Manager._request(self: any, store: any, key: string, transform: any, ids: any?): (boolean, any)
	local deadline = self._clock() + self._timeout
	local attempts = 0
	local reason = "Persistence request timed out"
	while self._clock() < deadline and attempts < self._attempts do
		local allowed, budget = true, true
		if self._adapter.CanRequest then
			allowed, budget = pcall(self._adapter.CanRequest, self._adapter)
		end
		if not allowed then
			return false, tostring(budget)
		end
		if budget then
			attempts += 1
			local permanent: string? = nil
			local ok, updated = pcall(function()
				return self._adapter:Update(store._name, key, function(current: any)
					local success, output = pcall(Value.Sync, transform, current)
					if not success then
						permanent = tostring(output)
						return nil
					end
					return output
				end, ids)
			end)
			if permanent then
				return false, permanent
			end
			if ok then
				if updated == nil then
					return false, "Persistence write was cancelled"
				end
				return true, updated
			end
			reason = tostring(updated)
			local retryable = false
			if self._adapter.IsRetryable then
				local checked, transient = pcall(self._adapter.IsRetryable, self._adapter, reason)
				retryable = checked and transient == true
			end
			if not retryable then
				return false, reason
			end
			event(self, "Retry", store._name, key, reason)
		end
		if attempts >= self._attempts then
			break
		end
		local delay = if budget then math.min(2 ^ (attempts - 1) * 0.25, 3) * (0.75 + self._random() * 0.5) else 0.1
		local ok, message = pause(self, math.min(delay, math.max(0, deadline - self._clock())))
		if not ok then
			return false, message
		end
	end
	return false, reason
end
function Manager.GetStore(self: any, name: string): any
	assert(self._stores[name], `Unknown persistence store: {name}`)
	return self._stores[name]
end
function Store.LoadPlayer(self: any, player: any): (any?, string?)
	return self:Load(`User_{player.UserId}`, player.UserId)
end
function Store.Load(self: any, key: string, userId: number?): (any?, string?)
	assert(type(key) == "string" and #key > 0 and #key <= 50 and utf8.len(key), "Invalid persistence key")
	assert(
		userId == nil or (type(userId) == "number" and userId >= 1 and userId < math.huge and userId % 1 == 0),
		"Invalid UserId"
	)
	local manager = self._manager
	local id = `{#self._name}:{self._name}{key}`
	local session: any = nil
	local ok, reason = manager:_exclusive(id, function(): (boolean, any)
		if manager._stopping then
			return false, "Persistence is stopping"
		end
		local cached = manager._sessions[id]
		if cached then
			if cached._userId ~= userId then
				return false, "Profile owner differs"
			end
			if cached._state ~= "Active" or cached._expires <= manager._wall() then
				return false, "Profile is unavailable"
			end
			session = cached
			return true, nil
		end
		if userId and manager._players and not manager._players:GetPlayerByUserId(userId) then
			return false, "Player already left"
		end
		for pendingId, pending in manager._loads do
			if pending.Expires <= manager._wall() and not manager._busy[pendingId] then
				manager._loads[pendingId] = nil
			end
		end
		local loading = manager._loads[id]
		if loading then
			if loading.UserId ~= userId then
				return false, "Profile owner differs"
			end
		else
			local count = 0
			for _ in manager._loads do
				count += 1
			end
			if count >= 1024 then
				return false, "Too many pending profile loads"
			end
			loading = {
				Owner = manager:_token(),
				Operation = manager:_token(),
				UserId = userId,
				Expires = manager._wall() + self._ttl + manager._timeout,
			}
			manager._loads[id] = loading
		end
		local owner, operation = loading.Owner, loading.Operation
		local success, result = manager:_request(self, key, function(current: any)
			if
				current
				and current.LastWrite == operation
				and current.Lock
				and current.Lock.Owner == owner
				and current.Lock.Expires > manager._wall()
			then
				return current
			end
			local now = manager._wall()
			local schema, data, revision, schemaRevision
			if current == nil then
				data = Value.Copy(self._schema.Defaults)
				revision, schemaRevision = 0, 1
			else
				current = record(current)
				assert(
					current.Lock == nil or current.Lock.Expires <= now or current.Lock.Owner == owner,
					"Profile is locked by another session"
				)
				local changed
				data, changed = self._schema:Upgrade(current.Schema, current.Data)
				revision = current.Revision
				schemaRevision = current.Schema.Revision + (if changed then 1 else 0)
			end
			schema = { Id = self._schema.Id, Shape = Value.Copy(self._schema.Shape), Revision = schemaRevision }
			return {
				Format = 1,
				Data = data,
				Schema = schema,
				Revision = revision + 1,
				Lock = { Owner = owner, Expires = now + self._ttl },
				LastWrite = operation,
			}
		end, if userId then { userId } else nil)
		if not success then
			event(manager, "LoadFailed", self._name, key, tostring(result))
			return false, result
		end
		session = setmetatable({
			_manager = manager,
			_store = self,
			_id = id,
			_key = key,
			_owner = owner,
			_userId = userId,
			_data = Value.Copy(result.Data),
			_schema = Value.Copy(result.Schema),
			_revision = result.Revision,
			_expires = result.Lock.Expires,
			_generation = 0,
			_saved = 0,
			_state = "Active",
			_error = nil,
			_next = manager._clock() + self._interval * (0.5 + manager._random() * 0.5),
		}, Session)
		manager._sessions[id] = session
		manager._loads[id] = nil
		event(manager, "Loaded", self._name, key)
		return true, nil
	end)
	if not ok then
		return nil, tostring(reason)
	end
	-- PlayerRemoving may have fired while UpdateAsync was yielding.
	if
		manager._stopping
		or session._expires <= manager._wall()
		or (userId and manager._players and not manager._players:GetPlayerByUserId(userId))
	then
		session:Release()
		return nil, "Profile load cancelled"
	end
	return session, nil
end
local function active(self: any)
	assert(self._state == "Active" and not self._manager._stopping, "Profile is not active")
	if self._expires <= self._manager._wall() then
		self._state = "Lost"
		error("Profile lease expired", 0)
	end
end
function Session.Get(self: any): any
	active(self)
	return Value.Copy(self._data)
end
function Session.Update(self: any, transform: any): (boolean, string?)
	if self._editing then
		return false, "Reentrant profile Update is not supported"
	end
	self._editing = true
	local ok, result = pcall(function()
		active(self)
		local generation = self._generation
		local changed = Value.Sync(transform, Value.Copy(self._data))
		assert(generation == self._generation, "Nested profile Update is not supported")
		active(self)
		return self._store._schema:Validate(changed)
	end)
	self._editing = false
	if not ok then
		return false, tostring(result)
	end
	self._data, self._generation = result, self._generation + 1
	return true, nil
end
function Session._write(self: any, release: boolean): (boolean, string?)
	if self._editing then
		return false, "Cannot save or release inside a profile transform"
	end
	local manager = self._manager
	return manager:_exclusive(self._id, function(): (boolean, any)
		if self._state == "Closed" then
			return true, nil
		end
		if self._state == "Lost" then
			return false, "Profile lease was lost"
		end
		if self._state == "Closing" and not release then
			return false, "Profile is closing"
		end
		if release then
			self._state = "Closing"
		end
		-- Retain uncertain writes across public calls; never advance to a newer snapshot first.
		for _ = 1, 2 do
			local pending = self._pending
			if not pending then
				pending = {
					Operation = manager:_token(),
					Data = Value.Copy(self._data),
					Generation = self._generation,
					Revision = self._revision,
					Release = release,
				}
				self._pending = pending
			end
			local success, result = manager:_request(self._store, self._key, function(current: any)
				current = record(current)
				if current.LastWrite == pending.Operation then
					return current
				end
				assert(
					current.Lock and current.Lock.Owner == self._owner and current.Lock.Expires > manager._wall(),
					"Profile lease was lost"
				)
				assert(current.Revision == pending.Revision, "Profile revision conflict")
				local updated = Value.Copy(current)
				updated.Data = pending.Data
				updated.Revision += 1
				updated.LastWrite = pending.Operation
				updated.Lock = if pending.Release
					then nil
					else { Owner = self._owner, Expires = manager._wall() + self._store._ttl }
				return updated
			end, if self._userId then { self._userId } else nil)
			if not success then
				self._error = tostring(result)
				if self._error:find("lease was lost", 1, true) or self._error:find("revision conflict", 1, true) then
					self._state = "Lost"
				end
				self._next = manager._clock() + math.min(5, self._store._interval / 2)
				event(manager, "SaveFailed", self._store._name, self._key, self._error)
				return false, self._error
			end
			self._pending = nil
			self._revision, self._saved, self._error = result.Revision, pending.Generation, nil
			self._next = manager._clock() + self._store._interval * (0.9 + manager._random() * 0.2)
			if pending.Release then
				self._state = "Closed"
				manager._sessions[self._id] = nil
			else
				self._expires = result.Lock.Expires
				if self._expires <= manager._wall() then
					self._state = "Lost"
					return false, "Profile lease expired while confirming save"
				end
			end
			event(manager, if pending.Release then "Released" else "Saved", self._store._name, self._key)
			if not release or pending.Release then
				return true, nil
			end
		end
		return false, "Persistence release was not completed"
	end)
end
function Session.Save(self: any): (boolean, string?)
	return self:_write(false)
end
function Session.Release(self: any): (boolean, string?)
	return self:_write(true)
end
function Session.GetStatus(self: any): any
	return {
		State = if self._state == "Active" and self._expires <= self._manager._wall() then "Lost" else self._state,
		Dirty = self._generation ~= self._saved,
		Revision = self._revision,
		SchemaId = self._schema.Id,
		SchemaRevision = self._schema.Revision,
		Expires = self._expires,
		Error = self._error,
	}
end
function Manager.Step(self: any)
	if self._stopping then
		return
	end
	for _, session in table.clone(self._sessions) do
		if self._stopping then
			break
		end
		if session._next <= self._clock() and not self._busy[session._id] and not session._scheduled then
			if session._state ~= "Active" and session._state ~= "Closing" then
				continue
			end
			session._scheduled = true
			local function save()
				local ok, reason = pcall(function()
					if session._state == "Closing" then
						session:Release()
					elseif session._state == "Active" then
						session:Save()
					end
				end)
				session._scheduled = false
				if not ok then
					event(self, "SaveFailed", session._store._name, session._key, tostring(reason))
				end
			end
			if self._spawn then
				local ok, reason = pcall(self._spawn, save)
				if not ok then
					session._scheduled = false
					event(self, "SaveFailed", session._store._name, session._key, tostring(reason))
				end
			else
				save()
			end
		end
	end
end
function Manager.GetSnapshot(self: any): any
	local sessions = {}
	for _, session in self._sessions do
		local status = session:GetStatus()
		status.Store, status.Key, status.UserId = session._store._name, session._key, session._userId
		table.insert(sessions, status)
	end
	return { Stopping = self._stopping, Sessions = sessions, History = self._history:Snapshot() }
end
function Manager.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._stopping = true
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	if self._playerConnection then
		self._playerConnection:Disconnect()
		self._playerConnection = nil
	end
	local pending, errors = 0, {}
	for _, session in table.clone(self._sessions) do
		pending += 1
		local function close()
			local ok, reason = session:Release()
			if not ok then
				table.insert(errors, tostring(reason))
			end
			pending -= 1
		end
		if self._spawn then
			(self._spawn :: any)(close)
		else
			close()
		end
	end
	local deadline = self._clock() + self._shutdown
	while (pending > 0 or next(self._busy) ~= nil) and self._clock() < deadline do
		local ok = pause(self, math.min(0.05, deadline - self._clock()))
		if not ok then
			break
		end
	end
	self._destroyed = pending == 0 and next(self._busy) == nil and next(self._sessions) == nil and #errors == 0
	assert(
		self._destroyed,
		`Persistence shutdown incomplete: {pending} pending; inspect remaining sessions; {table.concat(errors, "; ")}`
	)
end
return Manager
