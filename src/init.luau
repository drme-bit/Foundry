--!strict
local Environment = require("@self/Roblox/Environment")
local Dependencies = require("@self/Roblox/Dependencies")
local ApplicationContext = require("@self/Context/Container")
local Scope = require("@self/Lifecycle/Scope")
local Module = require("@self/Context/Module")
local Boot = require("@self/Context/Boot")
local Builder = require("@self/Context/Builder")
local Logger = require("@self/Diagnostics/Logger")
local Runtime = require("@self/Lifecycle/Runtime")
local Scheduler = require("@self/Tasks/Scheduler")
local Sidewatcher = require("@self/Diagnostics/Sidewatcher")
local Host = require("@self/Network/Host")
local Contract = require("@self/Network/Contract")
local SwiftPacket = require("@self/Network/Adapters/SwiftPacket")

local Validation = require("@self/Utility/Validation")
local Signal = require("@self/Utility/Signal")
local Registry = require("@self/Players/Registry")
local Player = require("@self/Players/Player")
local ServerInfo = require("@self/Server/Info")
export type Player = Player.Player
export type PlayerModule = Registry.Module
export type Application = Boot.Application
export type ApplicationBuilder = Builder.Builder
export type Health = { Status: string, Reason: string?, [string]: any }
export type ApplicationContext = ApplicationContext.ApplicationContext
export type Definition = ApplicationContext.Definition
export type LogPort = ApplicationContext.LogPort
export type ContextScope = ApplicationContext.Scope
export type Options = Boot.Options
export type ShutdownOptions = Boot.ShutdownOptions
export type Module = Module.Definition
export type Scope = Scope.Scope
export type Runtime = Runtime.Runtime
export type Logger = Logger.Logger
export type Sidewatcher = Sidewatcher.Sidewatcher

local Persistence = require("@self/Persistence/Manager")
local Memory = require("@self/Persistence/Adapters/Memory")
export type PersistenceOptions = Persistence.Options
export type StoreOptions = Persistence.StoreOptions
local Foundry = {
	Persistence = table.freeze(
		{
			new = Persistence.new,
			Memory = Memory
		}
	),
	t = Dependencies.t,
	Utility = table.freeze(
		{
			Validation = Validation,
			Signal = Signal,
			Trove = Dependencies.Trove
		}
	),
	Players = table.freeze(
		{ Registry = Registry }
	),
	Server = table.freeze(
		{ Info = ServerInfo }
	),
	Validation = Validation,
	Boot = Boot.new,
	Module = Module.new,
	Scope = Scope,
	Logger = Logger,
	Scheduler = Scheduler,
	Sidewatcher = Sidewatcher,
	Network = table.freeze(
		{
			Host = Host,
			Contract = Contract,
			SwiftPacket = SwiftPacket
		}
	),
	Core = table.freeze(
		{
			ApplicationContext = ApplicationContext,
			Scope = Scope
		}
	),
}

local function create(side: string, supplied: Boot.Options?): Boot.Application
	local options: Boot.Options = table.clone(supplied or ({} :: Boot.Options))
	assert(options.Side == nil or options.Side == side, "Context side cannot be overridden")
	if options.Platform then
		local matches = if side == "Server" then options.Platform:IsServer() else options.Platform:IsClient()
		assert(matches == true, `Cannot create {side}Context on this runtime`)
	end
	options.Side = side
	options.Name = options.Name or `Foundry/{side}`
	if options.Network then
		local network = table.clone(options.Network)
		assert(network.Side == nil or network.Side == side, "Network side differs from context")
		network.Side = side
		options.Network = network
	end
	return Boot.new(options)
end
-- Detect the execution side; engine defaults can be replaced by explicit test ports.
function Foundry.ApplicationContext(first: any, second: Boot.Options?): Boot.Application
	local supplied = if first == Foundry then second else first
	local options: Boot.Options = table.clone(supplied or ({} :: Boot.Options))
	local engine = Environment.Get()
	local platform = options.Platform or (if engine then engine.Platform else nil)
	assert(platform, "ApplicationContext requires Roblox or an explicit Platform port")
	local server, client = platform:IsServer(), platform:IsClient()
	assert(server ~= client and (server == true or client == true), "Cannot determine context execution side")
	local side = if server then "Server" else "Client"
	options.Platform = platform
	if engine then
		options.Wait = options.Wait or engine.Wait
		if server and options.Shutdown == nil then
			options.Shutdown = { Bind = engine.BindShutdown :: any }
		end
	end
	return create(side, options)
end
-- Both Foundry:ServerContext(options) and Foundry.ServerContext(options) are supported.
function Foundry.ServerContext(first: any, second: Boot.Options?): Boot.Application
	return create("Server", if first == Foundry then second else first)
end
function Foundry.ClientContext(first: any, second: Boot.Options?): Boot.Application
	return create("Client", if first == Foundry then second else first)
end
Foundry.Configure = function(supplied: Boot.Options?): Builder.Builder
	return Builder.new(function(options)
		return Foundry.ApplicationContext(options)
	end, supplied)
end
return table.freeze(Foundry)
