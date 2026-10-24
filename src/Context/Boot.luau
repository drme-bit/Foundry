--!strict
local Dependencies = require("../Roblox/Dependencies")
local ApplicationContext = require("./Container")
local Feature = require("./Feature")
local Scheduler = require("../Tasks/Scheduler")
local Contract = require("../Network/Contract")
local Infrastructure = require("./Infrastructure")
local Registry = require("../Players/Registry")
local ServerInfo = require("../Server/Info")
local Validation = require("../Utility/Validation")
local Inspector = require("../Diagnostics/Inspector")
type NetworkOptions = {
	Side: string?,
	Contracts: { Contract.Definition }?,
	CreateAdapter: ((any) -> any)?,
	Transport: string?,
	PacketsBinding: string?,
	Library: any?,
	Inject: { [string]: string }?,
	PeersRemoving: any?,
}
export type ShutdownOptions = { Bind: (() -> ()) -> () }
export type Options = {
	Shutdown: ShutdownOptions?,
	Players: Registry.Options?,
	Server: ServerInfo.Options?,
	Side: string?,
	Types: any?,
	Platform: any?,
	ConfigSchema: Validation.Check?,
	Scheduler: Scheduler.Options?,
	Network: NetworkOptions?,
	Inspector: { Enabled: boolean?, Render: ((any, any, any) -> ())? }?,
	Name: string?,
	Features: { Feature.Definition }?,
	Providers: { ApplicationContext.Definition }?,
	Values: { [string]: any }?,
	Config: any?,
	CreateScope: (() -> ApplicationContext.Scope)?,
	Logger: ApplicationContext.LogPort?,
	RetryAttempts: number?,
	RetryDelay: number?,
	Wait: ((number) -> ())?,
	Clock: (() -> number)?,
	HistoryLimit: number?,
}
type Data = {
	_bindShutdown: ((() -> ()) -> ())?,
	_shutdownTarget: { Application: any }?,
	_side: string,
	_config: any,
	_schema: Validation.Check?,
	_context: ApplicationContext.ApplicationContext,
	_features: { Feature.Definition },
	_bindings: { [string]: { Owner: string?, Dependencies: { string } } },
	_exports: { [string]: boolean },
	_started: boolean,
	_ready: boolean,
	_validationError: string?,
}
local Boot = {}
Boot.__index = Boot
export type Application = typeof(setmetatable({} :: Data, Boot))

local function register(self: Application, definition: ApplicationContext.Definition, owner: string?)
	local owned = table.clone(definition)
	owned.Feature = owner
	self._context:Register(owned)
	local dependencies = table.clone(definition.Dependencies or {})
	for _, name in definition.Inject or {} do
		table.insert(dependencies, name)
	end
	self._bindings[definition.Name] = { Owner = owner, Dependencies = dependencies }
end

local function value(self: Application, name: string, object: any, owner: string?)
	self._context:RegisterValue(name, object)
	self._bindings[name] = { Owner = owner, Dependencies = {} }
end

local function values(self: Application, objects: { [string]: any }, owner: string?)
	local keys = {}
	for name in objects do
		table.insert(keys, name)
	end
	table.sort(keys)
	for _, name in keys do
		value(self, name, objects[name], owner)
	end
end

function Boot.new(supplied: Options?): Application
	local options: Options = table.clone(supplied or ({} :: Options))
	if options.Types == nil then
		options.Types = Dependencies.t
	end
	local side = options.Side or "Shared"
	assert(side == "Shared" or side == "Server" or side == "Client", "Invalid context Side")
	assert(not options.Shutdown or side == "Server", "Shutdown is a server-only option")
	assert(not options.Shutdown or type(options.Shutdown.Bind) == "function", "Shutdown.Bind must be a function")
	local self = setmetatable({
		_bindShutdown = if options.Shutdown then options.Shutdown.Bind else nil,
		_shutdownTarget = nil,
		_side = side,
		_config = options.Config,
		_schema = options.ConfigSchema,
		_context = ApplicationContext.new(options),
		_features = {},
		_bindings = {},
		_exports = {},
		_started = false,
		_ready = false,
		_validationError = nil,
	}, Boot) :: Application
	assert(
		(not options.Players and not options.Server) or side == "Server",
		"Players and Server are server-only options"
	)
	Infrastructure.Register(self, options, register)
	values(self, options.Values or {}, nil)
	if options.Config ~= nil then
		value(self, "Config", options.Config, nil)
	end
	for _, definition in options.Providers or {} do
		register(self, definition, nil)
	end
	for _, descriptor in options.Features or {} do
		local feature = Feature.new(descriptor)
		table.insert(self._features, feature)
		values(self, feature.Values or {}, feature.Name)
		for _, definition in feature.Providers or {} do
			register(self, definition, feature.Name)
		end
		for _, name in feature.Exports or {} do
			self._exports[name] = true
		end
	end
	return self
end

-- Transitional root registrations remain useful for engine ports and application adapters.
function Boot.Register(self: Application, definition: ApplicationContext.Definition): Application
	assert(not self._started, "Registration is allowed only before Start")
	register(self, definition, nil)
	return self
end
function Boot.RegisterValue(self: Application, name: string, object: any): Application
	assert(not self._started, "Registration is allowed only before Start")
	value(self, name, object, nil)
	return self
end

function Boot.Start(self: Application): Application
	assert(not self._started, "A Foundry application can start only once")
	self._started = true
	local ok, message = pcall(function()
		Feature.Validate(self._features, self._bindings, self._side)
		if self._schema then
			local valid, reason = Validation.Check(self._schema, self._config)
			assert(valid, `Config validation failed: {reason}`)
		end
	end)
	if not ok then
		self._validationError = tostring(message)
		self._context:ReportValidationFailure(tostring(message))
		error(message, 0)
	end
	self._context:Run()
	self._ready = true
	local bind = self._bindShutdown
	self._bindShutdown = nil
	if bind then
		-- BindToClose cannot unsubscribe. Retain only a clearable holder in its callback.
		local target = { Application = self :: any }
		self._shutdownTarget = target
		local bound, reason = pcall(bind, function()
			local application = target.Application
			if application then
				application:Destroy()
			end
		end)
		if not bound then
			target.Application = nil
			self._shutdownTarget = nil
			self:Destroy()
			error(`Shutdown.Bind failed: {tostring(reason)}`, 0)
		end
	end
	return self
end
Boot.Run = Boot.Start

function Boot.Get(self: Application, name: string): any
	local binding = self._bindings[name]
	assert(not binding or not binding.Owner or self._exports[name], `Private feature binding: {name}`)
	return self._context:Get(name)
end
function Boot.GetSide(self: Application): string
	return self._side
end
function Boot.GetState(self: Application): string
	local state = self._context:GetState()
	return if state == "New" and self._validationError then "Failed" else state
end
function Boot.GetStatus(self: Application): any
	return self._context:GetStatus()
end
function Boot.GetGraph(self: Application): { any }
	local nodes = {}
	for name, binding in self._bindings do
		table.insert(nodes, { Name = name, Feature = binding.Owner, Dependencies = table.clone(binding.Dependencies) })
	end
	table.sort(nodes, function(a: any, b: any)
		return a.Name < b.Name
	end)
	return nodes
end
function Boot.Inspect(self: Application): any
	return Inspector.new(self):GetSnapshot()
end

function Boot.GetHistory(self: Application): { any }
	return self._context:GetHistory()
end
function Boot.GetLogger(self: Application): any
	return self._context:GetLogger()
end
function Boot.Execute(self: Application, name: string, operation: string, callback: any, ...: any): (boolean, ...any)
	local binding = self._bindings[name]
	assert(not binding or not binding.Owner or self._exports[name], `Private feature binding: {name}`)
	return self._context:Execute(name, operation, callback, ...)
end

function Boot.RetryFailed(self: Application): any
	return self._context:RetryFailed()
end
function Boot.Destroy(self: Application): { string }
	local errors = self._context:Destroy()
	self._ready = false
	self._bindShutdown = nil
	if self._shutdownTarget then
		self._shutdownTarget.Application = nil
		self._shutdownTarget = nil
	end
	return errors
end
return Boot
