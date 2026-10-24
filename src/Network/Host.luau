--!strict
local Dependencies = require("../Roblox/Dependencies")
local Contract = require("./Contract")
local Host = {}
Host.__index = Host
export type Options = {
	Side: string,
	Types: any?,
	Contracts: { Contract.Definition },
	Adapter: any,
	Clock: (() -> number)?,
	Logger: any?,
	PeersRemoving: any?,
}
type Data = {
	_side: string,
	_contracts: any,
	_adapter: any,
	_clock: () -> number,
	_logger: any,
	_stopped: boolean,
	_connections: { any },
	_listeners: any,
	_metrics: any,
	_limits: any,
	_manifest: string,
	_peersConnection: any?,
}
export type Host = typeof(setmetatable({} :: Data, Host))
function Host.new(options: Options): Host
	assert(options.Side == "Server" or options.Side == "Client", "Invalid network side")
	local contracts =
		Contract.Registry(options.Contracts, if options.Types ~= nil then options.Types else Dependencies.t)
	local self = setmetatable({
		_side = options.Side,
		_contracts = contracts,
		_adapter = options.Adapter,
		_clock = options.Clock or os.clock,
		_logger = options.Logger,
		_stopped = false,
		_connections = {},
		_listeners = {},
		_metrics = {},
		_limits = setmetatable({}, { __mode = "k" }),
		_manifest = Contract.Manifest(contracts),
		_peersConnection = nil,
	}, Host) :: Host
	for name in contracts do
		self._metrics[name] = { Received = 0, Sent = 0, Rejected = 0, Errors = 0 }
	end
	if options.PeersRemoving then
		self._peersConnection = options.PeersRemoving:Connect(function(peer)
			self._limits[peer] = nil
		end)
	end
	return self
end
function Host.GetManifest(self: Host): string
	return self._manifest
end
function Host.IsCompatible(self: Host, manifest: string): boolean
	return manifest == self._manifest
end
local function reject(self: Host, name: string)
	self._metrics[name].Rejected += 1
end
function Host.On(self: Host, name: string, callback: any): any
	local definition = self._contracts[name]
	assert(
		not self._stopped and definition and definition.ReceiveOn == self._side,
		`Cannot receive {name} on {self._side}`
	)
	assert(type(callback) == "function", "Handler must be a function")
	local listeners = self._listeners[name]
	if not listeners then
		listeners = {}
		self._listeners[name] = listeners
		local handlers = listeners
		local connection = self._adapter:On(name, function(...)
			if self._stopped then
				return
			end
			local incoming = table.pack(...)
			local peer = if self._side == "Server" then incoming[1] else nil
			local payload = if self._side == "Server"
				then table.pack(table.unpack(incoming, 2, incoming.n))
				else incoming
			local metrics = self._metrics[name]
			metrics.Received += 1
			local valid = Contract.Validate(definition, payload)
			if not valid then
				reject(self, name)
				return
			end
			if self._side == "Server" and definition.RateLimit and not self._adapter.EnforcesRateLimit then
				if peer == nil then
					reject(self, name)
					return
				end
				local perPeer = self._limits[peer]
				if not perPeer then
					perPeer = {}
					self._limits[peer] = perPeer
				end
				local stamp = self._clock()
				local limit = perPeer[name]
				if not limit or stamp - limit.Since >= definition.RateLimit[2] then
					limit = { Since = stamp, Count = 0 }
					perPeer[name] = limit
				end
				if limit.Count >= definition.RateLimit[1] then
					reject(self, name)
					return
				end
				limit.Count += 1
			end
			for _, entry in table.clone(handlers) do
				if not entry.Active then
					continue
				end
				local ok, reason = xpcall(entry.Callback, function(message: any)
					return debug.traceback(tostring(message), 2)
				end, table.unpack(incoming, 1, incoming.n))
				if not ok then
					metrics.Errors += 1
					if self._logger then
						pcall(function()
							self._logger:Error("Network handler failed", { Channel = name, Reason = tostring(reason) })
						end)
					end
				end
			end
		end)
		table.insert(self._connections, connection)
	end
	local entry: any = { Active = true, Callback = callback }
	table.insert(listeners, entry)
	local subscription = {}
	function subscription:Disconnect()
		if not entry.Active then
			return
		end
		entry.Active = false
		entry.Callback = nil
		local index = table.find(listeners, entry)
		if index then
			table.remove(listeners, index)
		end
	end
	return subscription
end
function Host.Send(self: Host, name: string, values: any, target: any?)
	local definition = self._contracts[name]
	assert(
		not self._stopped and definition and definition.ReceiveOn ~= self._side,
		`Cannot send {name} on {self._side}`
	)
	assert(target == nil or self._side == "Server", "Only the server can target a peer")
	local ok, reason = Contract.Validate(definition, values)
	assert(ok, reason)
	self._adapter:Send(name, values, target)
	self._metrics[name].Sent += 1
end
function Host.GetPackets(self: Host): any
	local channels: any = {}
	for name, definition in self._contracts do
		local channel: any = {}
		if definition.ReceiveOn == self._side then
			channel[if self._side == "Server" then "OnServerEvent" else "OnClientEvent"] = {
				Connect = function(_, callback)
					return self:On(name, callback)
				end,
			}
		else
			channel.Fire = function(_, ...)
				self:Send(name, table.pack(...))
			end
			if self._side == "Server" then
				channel.FireClient = function(_, peer, ...)
					self:Send(name, table.pack(...), peer)
				end
			end
		end
		channels[name] = table.freeze(channel)
	end
	return table.freeze(channels)
end
function Host.GetSnapshot(self: Host): any
	local channels: any = {}
	for name, definition in self._contracts do
		local item = table.clone(self._metrics[name])
		item.Name, item.ReceiveOn = name, definition.ReceiveOn
		table.insert(channels, item)
	end
	table.sort(channels, function(a: any, b: any)
		return a.Name < b.Name
	end)
	return { Side = self._side, Stopped = self._stopped, Manifest = self._manifest, Channels = channels }
end
function Host.Destroy(self: Host)
	if self._stopped then
		return
	end
	self._stopped = true
	for _, listeners in self._listeners do
		for _, entry in listeners do
			entry.Active = false
			entry.Callback = nil
		end
	end
	local errors = {}
	for _, connection in self._connections do
		local ok, reason = pcall(function()
			connection:Disconnect()
		end)
		if not ok then
			table.insert(errors, tostring(reason))
		end
	end
	if self._peersConnection then
		local ok, reason = pcall(function()
			self._peersConnection:Disconnect()
		end)
		if not ok then
			table.insert(errors, tostring(reason))
		end
	end
	table.clear(self._listeners)
	table.clear(self._limits)
	table.clear(self._connections)
	if #errors > 0 then
		error(table.concat(errors, "\n"), 0)
	end
end
return Host
