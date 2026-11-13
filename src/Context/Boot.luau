--!strict
local Persistence = require("../Persistence/Manager")
local Dependencies = require("../Roblox/Dependencies")
local ApplicationContext = require("./Container")
local Module = require("./Module")
local Scheduler = require("../Tasks/Scheduler")
local Contract = require("../Network/Contract")
local Infrastructure = require("./Infrastructure")
local Registry = require("../Players/Registry")
local ServerInfo = require("../Server/Info")
local Validation = require("../Utility/Validation")
local Inspector = require("../Diagnostics/Inspector")
local Sidewatcher = require("../Diagnostics/Sidewatcher")
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
export type ShutdownOptions = {
	Bind: (() -> ()) -> (),
	Before: ((any) -> ())?,
	After: ((any, { string }) -> ())?,
}
export type Options = {
	Persistence: Persistence.Options?,
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
	Modules: { Module.Definition }?,
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
	_modules: { Module.Definition },
	_bindings: { [string]: { Owner: string?, Dependencies: { string } } },
	_exports: { [string]: boolean },
	_started: boolean,
	_ready: boolean,
	_validationError: string?,
	_sidewatcher: Sidewatcher.Sidewatcher?,
	_watcherScheduler: Scheduler.Scheduler?,
	_watcherOptions: Scheduler.Options,
	_watcherClock: (() -> number)?,
	_watcherPulse: any?,
	_shutdownBefore: ((any) -> ())?,
	_shutdownAfter: ((any, { string }) -> ())?,
	_clock: () -> number,
	_startupStarted: number?,
	_startupFinished: number?,
	_shutdownComplete: boolean,
}
local Boot = {}
Boot.__index = Boot
export type Application = typeof(setmetatable({} :: Data, Boot))

local function clock(self: Application): number
	local ok, value = pcall(self._clock)
	return if ok
			and type(value) == "number"
			and value == value
			and math.abs(value) < math.huge
		then value
		else os.clock()
end

local function register(self: Application, definition: ApplicationContext.Definition, owner: string?)
	local owned = table.clone(definition)
	owned.Module = owner
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
	assert(not options.Shutdown or options.Shutdown.Before == nil or type(options.Shutdown.Before) == "function", "Shutdown.Before must be a function")
	assert(not options.Shutdown or options.Shutdown.After == nil or type(options.Shutdown.After) == "function", "Shutdown.After must be a function")
	local self = setmetatable({
		_bindShutdown = if options.Shutdown then options.Shutdown.Bind else nil,
		_shutdownTarget = nil,
		_side = side,
		_config = options.Config,
		_schema = options.ConfigSchema,
		_context = ApplicationContext.new(options),
		_modules = {},
		_bindings = {},
		_exports = {},
		_started = false,
		_ready = false,
		_validationError = nil,
		_sidewatcher = nil,
		_watcherScheduler = nil,
		_watcherOptions = table.clone(options.Scheduler or {}),
		_watcherClock = options.Clock,
		_watcherPulse = if options.Scheduler and options.Scheduler.Pulse
			then options.Scheduler.Pulse
			else (options.Platform and options.Platform.Heartbeat),
		_shutdownBefore = if options.Shutdown then options.Shutdown.Before else nil,
		_shutdownAfter = if options.Shutdown then options.Shutdown.After else nil,
		_clock = options.Clock or os.clock,
		_startupStarted = nil,
		_startupFinished = nil,
		_shutdownComplete = false,
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
	for _, descriptor in options.Modules or {} do
		local module = Module.new(descriptor)
		table.insert(self._modules, module)
		values(self, module.Values or {}, module.Name)
		for _, definition in module.Providers or {} do
			register(self, definition, module.Name)
		end
		for _, name in module.Exports or {} do
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
	self._startupStarted = clock(self)
	local ok, message = pcall(function()
		Module.Validate(self._modules, self._bindings, self._side)
		if self._schema then
			local valid, reason = Validation.Check(self._schema, self._config)
			assert(valid, `Config validation failed: {reason}`)
		end
	end)
	if not ok then
		self._validationError = tostring(message)
		self._context:ReportValidationFailure(tostring(message))
		self._startupFinished = clock(self)
		error(message, 0)
	end
	self._context:Run()
	self._startupFinished = clock(self)
	self._ready = true
	local watcherOptions = table.clone(self._watcherOptions)
	watcherOptions.Clock = watcherOptions.Clock or self._watcherClock
	watcherOptions.Pulse = watcherOptions.Pulse or self._watcherPulse
	watcherOptions.Logger = watcherOptions.Logger or self:GetLogger()
	watcherOptions.CanRun = function()
		return self._ready and self:GetState() == "Running"
	end
	self._watcherScheduler = Scheduler.new(watcherOptions)
	local watcher = Sidewatcher.new(self, self._watcherScheduler, self:GetLogger())
	self._sidewatcher = watcher
	watcher:Start()
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
	if name == "Sidewatcher" then
		assert(self._sidewatcher, "Sidewatcher is available only after Start")
		return self._sidewatcher
	end
	local binding = self._bindings[name]
	assert(not binding or not binding.Owner or self._exports[name], `Private module binding: {name}`)
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
		table.insert(nodes, { Name = name, Module = binding.Owner, Dependencies = table.clone(binding.Dependencies) })
	end
	table.sort(nodes, function(a: any, b: any)
		return a.Name < b.Name
	end)
	return nodes
end
function Boot.Inspect(self: Application): any
	return Inspector.new(self):GetSnapshot()
end

function Boot.GetHealth(self: Application): any
	local state = self:GetState()
	local status = self:GetStatus()
	local result = {
		Status = if state == "Running"
			then if status.Failed + status.Skipped + status.RuntimeFailures > 0 then "Degraded" else "Ready"
			elseif state == "Stopped" then "Stopped"
			elseif state == "Failed" then "Failed"
			else "Starting",
		State = state,
		Reason = nil,
		Beans = {},
	}
	for name, bean in status.Beans do
		local health = {
			Status = if bean.State == "Running" then "Ready" else bean.State,
			Reason = bean.Reason,
		}
		local ok, instance = pcall(function()
			return self._context:Get(name)
		end)
		if ok and type(instance.Health) == "function" then
			local healthy, value = pcall(instance.Health, instance)
			if healthy and type(value) == "table" then
				health = table.clone(value)
			elseif not healthy then
				health.Status, health.Reason = "Degraded", tostring(value)
			end
		end
		result.Beans[name] = health
	end
	return result
end

function Boot.GetStartupReport(self: Application): any
	local status = self:GetStatus()
	local slowest = {}
	for name, bean in status.Beans do
		local duration = (bean.CreateDuration or 0) + (bean.InitDuration or 0) + (bean.StartDuration or 0)
		table.insert(slowest, { Name = name, Duration = duration, Module = bean.Module })
	end
	table.sort(slowest, function(a: any, b: any)
		return a.Duration > b.Duration
	end)
	return {
		StartedAt = self._startupStarted,
		FinishedAt = self._startupFinished,
		Duration = if self._startupStarted and self._startupFinished
			then math.max(0, self._startupFinished - self._startupStarted)
			else nil,
		Status = status,
		Slowest = slowest,
	}
end

function Boot.GetHistory(self: Application): { any }
	return self._context:GetHistory()
end
function Boot.GetLogger(self: Application): any
	return self._context:GetLogger()
end
function Boot.Execute(self: Application, name: string, operation: string, callback: any, ...: any): (boolean, ...any)
	local binding = self._bindings[name]
	assert(not binding or not binding.Owner or self._exports[name], `Private module binding: {name}`)
	return self._context:Execute(name, operation, callback, ...)
end

function Boot.RetryFailed(self: Application): any
	return self._context:RetryFailed()
end
function Boot.Destroy(self: Application): { string }
	if self._shutdownComplete then
		return {}
	end
	local errors = {}
	local before = self._shutdownBefore
	if before then
		local ok, reason = pcall(before, self)
		if not ok then
			table.insert(errors, `Shutdown.Before: {tostring(reason)}`)
		end
	end
	if self._sidewatcher then
		self._sidewatcher:Destroy()
		self._sidewatcher = nil
	end
	if self._watcherScheduler then
		self._watcherScheduler:Destroy()
		self._watcherScheduler = nil
	end
	for _, message in self._context:Destroy() do
		table.insert(errors, message)
	end
	local after = self._shutdownAfter
	if after then
		local ok, reason = pcall(after, self, errors)
		if not ok then
			table.insert(errors, `Shutdown.After: {tostring(reason)}`)
		end
	end
	self._ready = false
	self._bindShutdown = nil
	if self._shutdownTarget then
		self._shutdownTarget.Application = nil
		self._shutdownTarget = nil
	end
	self._shutdownComplete = true
	return errors
end
return Boot
