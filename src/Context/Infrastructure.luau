--!strict
local Dependencies = require("../Roblox/Dependencies")
local Scheduler = require("../Tasks/Scheduler")
local Host = require("../Network/Host")
local Contract = require("../Network/Contract")
local SwiftPacket = require("../Network/Adapters/SwiftPacket")
local Inspector = require("../Diagnostics/Inspector")
local Registry = require("../Players/Registry")
local ServerInfo = require("../Server/Info")
local Persistence = require("../Persistence/Manager")
local Infrastructure = {}
function Infrastructure.Register(self: any, options: any, register: any)
	local side = self:GetSide()
	if options.Persistence then
		assert(side == "Server", "Persistence is server-only")
		local config = table.clone(options.Persistence)
		config.Clock = config.Clock or options.Clock
		config.Wait = config.Wait or options.Wait
		config.Logger = config.Logger or self._context:GetLogger()
		register(self, {
			Name = "Persistence",
			Create = function()
				return Persistence.new(config)
			end,
		}, nil)
		for name in config.Stores or {} do
			register(self, {
				Name = name,
				Inject = { Persistence = "Persistence" },
				Create = function(deps)
					return deps.Persistence:GetStore(name)
				end,
			}, nil)
		end
	end
	if options.Scheduler then
		local config = table.clone(options.Scheduler)
		config.Clock = config.Clock or options.Clock
		config.Logger = config.Logger or self._context:GetLogger()
		config.CanRun = function()
			return self._ready and self:GetState() == "Running"
		end
		register(self, {
			Name = "Scheduler",
			Create = function()
				return Scheduler.new(config)
			end,
		}, nil)
	end
	if options.Network then
		local config = table.clone(options.Network)
		assert(config.Side == "Server" or config.Side == "Client", "Network needs a Side")
		assert(side == "Shared" or side == config.Side, "Network side differs from context")
		config.Transport = config.Transport or "SwiftPacket"
		assert(
			config.CreateAdapter or config.Transport == "SwiftPacket",
			`Unknown network transport: {config.Transport}`
		)
		local precompiled = not config.CreateAdapter and not config.Library and config.PacketsBinding ~= nil
		local contracts = {}
		for _, definition in config.Contracts or {} do
			table.insert(contracts, Contract.new(definition))
		end
		for _, feature in options.Features or {} do
			for _, definition in feature.Contracts or {} do
				table.insert(contracts, Contract.new(definition))
			end
		end
		Contract.Registry(contracts)
		register(self, {
			Name = "Network",
			Inject = config.Inject
				or (if precompiled then { Packets = config.PacketsBinding or "WirePackets" } else {}),
			Create = function(d, scope)
				local adapter
				if config.CreateAdapter then
					adapter = (config.CreateAdapter :: (any) -> any)(d)
				else
					local packets
					if precompiled then
						packets = d.Packets
					else
						local library = config.Library or Dependencies.GetSwiftPacket()
						packets = SwiftPacket.Define(library, contracts)
					end
					adapter = SwiftPacket.new(packets, config.Side :: string)
				end
				if adapter.Destroy then
					scope:Add(adapter, "Destroy")
				end
				return Host.new({
					Side = config.Side :: string,
					Types = options.Types,
					Contracts = contracts,
					Adapter = adapter,
					Clock = options.Clock,
					Logger = self._context:GetLogger(),
					PeersRemoving = config.PeersRemoving,
				})
			end,
		}, nil)
	end
	if options.Inspector and options.Inspector.Enabled then
		local render = options.Inspector.Render
		register(self, {
			Name = "Inspector",
			Dependencies = if options.Scheduler then { "Scheduler" } else {},
			Create = function(d, scope)
				local inspector: any = Inspector.new(self)
				if render then
					inspector.Start = function()
						(render :: (any, any, any) -> ())(inspector, scope, d.Scheduler)
					end
				end
				return inspector
			end,
		}, nil)
	end

	if options.Players then
		register(self, {
			Name = "PlayerRegistry",
			Create = function()
				local config = table.clone(options.Players)
				config.Clock = config.Clock or options.Clock
				config.Logger = config.Logger or self:GetLogger()
				config.Server = options.Server
				return Registry.new(config)
			end,
		}, nil)
	end
	if options.Server then
		register(self, {
			Name = "ServerInfo",
			Dependencies = if options.Players then { "PlayerRegistry" } else {},
			Create = function(deps: any)
				return ServerInfo.new(options.Server, self, deps.PlayerRegistry, options.Clock)
			end,
		}, nil)
	end
end
return Infrastructure
