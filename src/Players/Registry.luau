--!strict
local Scope = require("../Lifecycle/Scope")
local Signal = require("../Utility/Signal")
local Player = require("./Player")
export type Module = { Name: string, Create: (Player.Player, Scope.Scope) -> any }
export type Options = { Source: any, Modules: { Module }?, Clock: (() -> number)?, Logger: any?, Server: any? }
local Registry = {}
Registry.__index = Registry
export type Registry = typeof(setmetatable(
	{} :: {
		_source: any,
		_modules: { Module },
		_clock: () -> number,
		_logger: any,
		_server: any,
		_scope: Scope.Scope,
		_players: { [number]: Player.Player },
		_index: number,
		_started: boolean,
		_destroyed: boolean,
		Changed: Signal.Signal,
	},
	Registry
))
local function report(self: Registry, reason: string)
	if self._logger then
		pcall(function()
			self._logger:Error(reason)
		end)
	end
end
function Registry.new(options: Options): Registry
	assert(options.Source, "PlayerRegistry needs a Players source")
	local modules: { Module } = {}
	local names = {}
	for _, module in options.Modules or {} do
		assert(
			type(module.Name) == "string" and #module.Name > 0 and type(module.Create) == "function",
			"Invalid player module"
		)
		assert(not names[module.Name], `Duplicate player module: {module.Name}`)
		names[module.Name] = true
		local descriptor: Module = { Name = module.Name, Create = module.Create }
		table.insert(modules, table.freeze(descriptor) :: Module)
	end
	local self = setmetatable({
		_source = options.Source,
		_modules = modules,
		_clock = options.Clock or os.clock,
		_logger = options.Logger,
		_server = table.freeze(table.clone(options.Server or {})),
		_scope = Scope.new(),
		_players = {},
		_index = 0,
		_started = false,
		_destroyed = false,
		Changed = Signal.new(),
	}, Registry) :: Registry
	self.Changed._onError = function(reason)
		report(self, `Player observer failed: {reason}`)
	end
	return self
end
local function current(self: Registry, record: Player.Player): boolean
	return not self._destroyed and self._players[record.UserId] == record and record:GetStatus() ~= "Left"
end
local function remove(self: Registry, instance: any)
	local record = self._players[instance.UserId]
	if not record or record:GetInstance() ~= instance then
		return
	end
	self._players[record.UserId] = nil
	local ok, reason = pcall(function()
		record:Destroy()
	end)
	if not ok then
		report(self, `Player {record.UserId} cleanup failed: {reason}`)
	end
	self.Changed:Fire("Removed", record)
end
local function add(self: Registry, instance: any)
	if self._destroyed or self._players[instance.UserId] then
		return
	end
	self._index += 1
	local record = Player.new(instance, self._index, self._clock(), self._server)
	self._players[record.UserId] = record
	record._scope:Add(instance.CharacterAdded:Connect(function(character: any)
		if current(self, record) then
			record._character = character
			self.Changed:Fire("Character", record)
		end
	end))
	record._scope:Add(instance.CharacterRemoving:Connect(function(character: any)
		if current(self, record) and record._character == character then
			record._character = nil
			self.Changed:Fire("Character", record)
		end
	end))
	self.Changed:Fire("Added", record)
	for _, module in self._modules do
		if not current(self, record) then
			return
		end
		local scope = record._scope:Extend()
		local ok, result = pcall(module.Create, record, scope)
		if not current(self, record) then
			-- A yielding factory may return after PlayerRemoving/shutdown cleaned its scope.
			if ok and type(result) == "table" and type(result.Destroy) == "function" then
				local cleaned, reason = pcall(result.Destroy, result)
				if not cleaned then
					report(self, tostring(reason))
				end
			end
			return
		end
		if ok and result ~= nil then
			record._modules[module.Name] = result
			if type(result) == "table" and type(result.Destroy) == "function" then
				scope:Add(result, "Destroy")
			end
		else
			record._errors[module.Name] = if ok then "Factory returned nil" else tostring(result)
			report(self, `Player {record.UserId} module {module.Name} failed: {record._errors[module.Name]}`)
			local cleaned, reason = pcall(function()
				scope:Destroy()
			end)
			if not cleaned then
				report(self, tostring(reason))
			end
		end
	end
	if current(self, record) then
		record._status = if next(record._errors) then "Degraded" else "Ready"
		self.Changed:Fire("Ready", record)
	end
end
function Registry.Start(self: Registry)
	assert(not self._started and not self._destroyed, "PlayerRegistry can start only once")
	self._started = true
	self._scope:Add(self._source.PlayerAdded:Connect(function(instance: any)
		add(self, instance)
	end))
	self._scope:Add(self._source.PlayerRemoving:Connect(function(instance: any)
		remove(self, instance)
	end))
	for _, instance in self._source:GetPlayers() do
		-- A previous factory may have yielded while another player left.
		if instance.Parent == self._source then
			add(self, instance)
		end
	end
end
function Registry.GetPlayer(self: Registry, playerOrId: any): Player.Player?
	local id = if type(playerOrId) == "number" then playerOrId else playerOrId and playerOrId.UserId
	local record = self._players[id]
	if type(playerOrId) ~= "number" and record and record:GetInstance() ~= playerOrId then
		return nil
	end
	return record
end
function Registry.GetPlayers(self: Registry): { Player.Player }
	local players: { Player.Player } = {}
	for _, record in self._players do
		table.insert(players, record)
	end
	table.sort(players, function(a: Player.Player, b: Player.Player)
		return a.Index < b.Index
	end)
	return players
end
function Registry.GetSnapshot(self: Registry): any
	local players = {}
	for _, record in self:GetPlayers() do
		table.insert(players, record:GetSnapshot())
	end
	return {
		Count = #players,
		Players = players,
		State = if self._destroyed then "Stopped" elseif self._started then "Running" else "New",
	}
end
function Registry.Destroy(self: Registry)
	if self._destroyed then
		return
	end
	self._destroyed = true
	local ok, reason = pcall(function()
		self._scope:Destroy()
	end)
	if not ok then
		report(self, tostring(reason))
	end
	for _, record in self:GetPlayers() do
		remove(self, record:GetInstance())
	end
	self.Changed:Destroy()
	table.clear(self._modules)
	self._source = nil
end
return Registry
