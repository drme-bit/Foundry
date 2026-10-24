--!strict
local DefaultScope = require("../Lifecycle/Scope")
local Logger = require("../Diagnostics/Logger")
local Journal = require("../Utility/Journal")
local Runtime = require("../Lifecycle/Runtime")

-- Pure Luau composition/lifecycle container. Factories receive only declared dependencies.
export type Scope = {
	Destroy: (self: any) -> (),
	Add: <T>(self: any, object: T, method: any?, index: any?) -> T,
}
export type Definition = {
	Name: string,
	Dependencies: { string }?,
	Inject: { [string]: string }?,
	Create: (dependencies: { [string]: any }, scope: Scope, runtime: Runtime.Runtime) -> any,
	Feature: string?,
}
export type LogPort = { Debug: (any, string) -> (), Info: (any, string) -> (), Error: (any, string) -> () }
export type Options = {
	Name: string?,
	CreateScope: (() -> Scope)?,
	Logger: LogPort?,
	RetryAttempts: number?,
	RetryDelay: number?,
	Wait: ((number) -> ())?,
	Clock: (() -> number)?,
	HistoryLimit: number?,
}
type Entry = { Name: string, Instance: any, Scope: Scope, Runtime: Runtime.Runtime?, Alive: boolean }
type Data = {
	Name: string,
	_state: string,
	_definitions: { [string]: Definition },
	_names: { string },
	_values: { [string]: any },
	_instances: { [string]: any },
	_entries: { Entry },
	_createScope: () -> Scope,
	_logger: LogPort?,
	_statuses: { [string]: any },
	_order: { string },
	_retryAttempts: number,
	_retryDelay: number,
	_wait: ((number) -> ())?,
	_executing: boolean,
	_retrying: boolean,
	_history: Journal.Journal,
	_clock: () -> number,
	_revision: number,
	_cachedStatus: any,
	_runtimes: { [string]: Runtime.Runtime },
}
local function traceback(message: any): string
	return debug.traceback(tostring(message), 2)
end

local ApplicationContext = {}
ApplicationContext.__index = ApplicationContext
export type ApplicationContext = typeof(setmetatable({} :: Data, ApplicationContext))

local function now(self: ApplicationContext): number
	local ok, value = pcall(self._clock)
	return if ok
			and type(value) == "number"
			and value == value
			and math.abs(value) < math.huge
		then value
		else os.clock()
end
local function event(self: ApplicationContext, fields: any)
	self._revision += 1
	self._cachedStatus = nil
	local record = table.clone(fields)
	record.Time = now(self)
	record.Context = self.Name
	self._history:Push(record)
end

function ApplicationContext.new(supplied: Options?): ApplicationContext
	local options: Options = supplied or {}
	assert(options.CreateScope == nil or type(options.CreateScope) == "function", "Invalid CreateScope")
	local attempts, delay = options.RetryAttempts or 2, options.RetryDelay or 1
	assert(attempts >= 0 and attempts <= 10 and attempts % 1 == 0, "RetryAttempts must be an integer from 0 to 10")
	assert(delay >= 0 and delay < math.huge, "RetryDelay must be finite and nonnegative")
	return setmetatable({
		Name = options.Name or "Application",
		_state = "New",
		_definitions = {},
		_names = {},
		_values = {},
		_instances = {},
		_entries = {},
		_createScope = options.CreateScope or DefaultScope.new,
		_logger = options.Logger or Logger.new(options.Name or "Application"),
		_statuses = {},
		_order = {},
		_retryAttempts = attempts,
		_retryDelay = delay,
		_wait = options.Wait,
		_executing = false,
		_retrying = false,
		_history = Journal.new(options.HistoryLimit or 512),
		_clock = options.Clock or os.clock,
		_revision = 0,
		_cachedStatus = nil,
		_runtimes = {},
	}, ApplicationContext)
end

function ApplicationContext.GetState(self: ApplicationContext): string
	return self._state
end

local function assertAvailable(self: ApplicationContext, name: string)
	assert(self._state == "New", "Registration is allowed only before Run")
	assert(type(name) == "string" and #name > 0, "Bean name must be a nonempty string")
	assert(self._definitions[name] == nil and self._values[name] == nil, `Duplicate bean: {name}`)
end

-- External values are borrowed: the container never calls Destroy on them.
function ApplicationContext.RegisterValue(self: ApplicationContext, name: string, value: any): ApplicationContext
	assertAvailable(self, name)
	assert(value ~= nil, `Value {name} cannot be nil`)
	self._values[name] = value
	event(self, { Event = "ValueRegistered", Bean = name })
	return self
end

function ApplicationContext.Register(self: ApplicationContext, definition: Definition): ApplicationContext
	assertAvailable(self, definition.Name)
	assert(type(definition.Create) == "function", `Bean {definition.Name} needs a factory`)
	assert(not (definition.Inject and definition.Dependencies), "Use Inject or Dependencies, not both")
	local dependencies = table.clone(definition.Dependencies or {})
	local inject: { [string]: string }? = nil
	if definition.Inject then
		inject = table.clone(definition.Inject)
		local aliases = {}
		for alias, dependency in inject do
			assert(type(alias) == "string" and #alias > 0, "Invalid injection alias")
			assert(type(dependency) == "string" and #dependency > 0, "Invalid dependency name")
			table.insert(aliases, alias)
		end
		table.sort(aliases)
		local seen: { [string]: boolean } = {}
		for _, alias in aliases do
			local dependency = inject[alias]
			if not seen[dependency] then
				seen[dependency] = true
				table.insert(dependencies, dependency)
			end
		end
		table.freeze(inject)
	end
	local seen: { [string]: boolean } = {}
	for _, dependency in dependencies do
		assert(type(dependency) == "string" and #dependency > 0, "Invalid dependency name")
		assert(not seen[dependency], `Repeated dependency {dependency} in {definition.Name}`)
		seen[dependency] = true
	end
	self._definitions[definition.Name] = {
		Name = definition.Name,
		Dependencies = table.freeze(dependencies),
		Inject = inject,
		Create = definition.Create,
		Feature = definition.Feature,
	}

	table.insert(self._names, definition.Name)
	event(self, { Event = "Registered", Bean = definition.Name, Feature = definition.Feature })
	return self
end

function ApplicationContext.Get(self: ApplicationContext, name: string): any
	assert(self._state == "Running", "Get is available only after a successful Run")
	local value = self._values[name]
	if value ~= nil then
		return value
	end
	local instance = self._instances[name]
	assert(instance ~= nil, `Unknown bean: {name}`)
	return instance
end

local function resolveOrder(self: ApplicationContext): { string }
	local order, visiting, visited = {}, {} :: { [string]: boolean }, {} :: { [string]: boolean }
	local path: { string } = {}
	local function visit(name: string)
		if self._values[name] ~= nil or visited[name] then
			return
		end
		assert(self._definitions[name] ~= nil, `Missing dependency: {name}`)
		assert(not visiting[name], `Dependency cycle: {table.concat(path, " -> ")} -> {name}`)
		visiting[name] = true
		table.insert(path, name)
		local dependencies = self._definitions[name].Dependencies :: { string }
		for _, dependency in dependencies do
			visit(dependency)
		end
		table.remove(path)
		visiting[name] = nil
		visited[name] = true
		table.insert(order, name)
	end
	for _, name in self._names do
		visit(name)
	end
	return order
end

local function log(self: ApplicationContext, level: string, message: string, fields: any?)
	if self._logger then
		pcall(function()
			(self._logger :: any)[level](self._logger, message, fields)
		end)
	end
end

local function dispose(self: ApplicationContext, name: string): { string }
	local errors = {}
	for index = #self._entries, 1, -1 do
		local entry = self._entries[index]
		if entry.Name ~= name then
			continue
		end
		table.remove(self._entries, index)
		entry.Alive = false
		self._runtimes[name] = nil
		self._instances[name] = nil
		if entry.Instance then
			local ok, message = xpcall(function(): any
				local destroy = entry.Instance.Destroy
				if type(destroy) == "function" then
					(destroy :: (any) -> ())(entry.Instance)
				end
				return nil
			end, traceback)
			if not ok then
				table.insert(errors, `{name}.Destroy: {message}`)
			end
		end
		local ok, message = xpcall(function(): any
			entry.Scope:Destroy()
			return nil
		end, traceback)
		if not ok then
			table.insert(errors, `{name}.Scope: {message}`)
		end
		break
	end
	for _, message in errors do
		event(self, { Event = "CleanupFailed", Bean = name, Reason = message })
		log(self, "Error", message)
	end
	return errors
end

-- Cached snapshots never expose owned objects. Runtime errors are separate from lifecycle failure.
local function copyStatus(status: any): any
	local result = table.clone(status)
	result.Beans = {}
	for name, bean in status.Beans do
		result.Beans[name] = table.clone(bean)
	end
	return result
end
function ApplicationContext.GetStatus(self: ApplicationContext): any
	if self._cachedStatus then
		return copyStatus(self._cachedStatus)
	end
	local result = {
		Started = 0,
		Alive = 0,
		Failed = 0,
		Skipped = 0,
		Retried = 0,
		RuntimeFailures = 0,
		Revision = self._revision,
		Beans = {},
	}
	for name, status in self._statuses do
		result.Beans[name] = table.clone(status)
		result.RuntimeFailures += status.RuntimeFailures or 0
		if status.Started then
			result.Started += 1
		end
		if (status.Attempts or 0) > 1 then
			result.Retried += 1
		end
		if status.State == "Running" then
			result.Alive += 1
		elseif status.State == "Failed" then
			result.Failed += 1
		elseif status.State == "Skipped" then
			result.Skipped += 1
		end
	end
	self._cachedStatus = result
	return copyStatus(result)
end
function ApplicationContext.GetHistory(self: ApplicationContext): { any }
	return self._history:Snapshot()
end
function ApplicationContext.GetLogger(self: ApplicationContext): any
	return self._logger
end
function ApplicationContext.Execute(
	self: ApplicationContext,
	name: string,
	operation: string,
	callback: any,
	...: any
): (boolean, ...any)
	local runtime = self._runtimes[name]
	if self._state ~= "Running" or not runtime then
		return false, `Bean {name} is unavailable`
	end
	return runtime:Run(operation, callback, ...)
end
-- Reports composition errors through the same journal, before providers exist.
function ApplicationContext.ReportValidationFailure(self: ApplicationContext, reason: string)
	event(self, { Event = "ValidationFailed", Reason = reason })
	log(self, "Error", "Application validation failed", { Reason = reason })
end

local function summary(self: ApplicationContext, label: string)
	local status = self:GetStatus()
	local health = if status.Failed + status.Skipped + status.RuntimeFailures > 0 then "DEGRADED" else "OK"
	log(
		self,
		"Info",
		`{label} {health}: started={status.Started} alive={status.Alive} failed={status.Failed} skipped={status.Skipped} retried={status.Retried} total={#self._names}`
	)
end

local function execute(self: ApplicationContext, order: { string }, selected: { [string]: boolean })
	self._executing = true
	-- Reset only selected branches; running beans retain their identity and resources.
	for name in selected do
		local previous = self._statuses[name]
		self._statuses[name] = {
			State = "Pending",
			Attempts = if previous then previous.Attempts or 0 else 0,
			Feature = self._definitions[name].Feature,
		}
		event(self, { Event = "Pending", Bean = name })
	end
	local function fail(name: string, phase: string, message: string)
		local affected = { [name] = true }
		for _, candidate in order do
			for _, dependency in self._definitions[candidate].Dependencies or {} do
				if affected[dependency] then
					affected[candidate] = true
				end
			end
		end
		-- Dependents release references before the failed dependency is destroyed.
		for i = #order, 1, -1 do
			local candidate = order[i]
			if not affected[candidate] then
				continue
			end
			local previous = self._statuses[candidate]
			self._statuses[candidate] = {
				State = if candidate == name then "Failed" else "Skipped",
				Stage = phase,
				Reason = if candidate == name then message else `Dependency {name} unavailable`,
				Attempts = if previous then previous.Attempts or 0 else 0,
				CleanupFailed = previous and previous.CleanupFailed,
				CleanupError = previous and previous.CleanupError,
				Feature = self._definitions[candidate].Feature,
				CreateDuration = previous and previous.CreateDuration,
				InitDuration = previous and previous.InitDuration,
				StartDuration = previous and previous.StartDuration,
				RuntimeFailures = previous and previous.RuntimeFailures,
				LastRuntimeError = previous and previous.LastRuntimeError,
			}
			event(self, {
				Event = self._statuses[candidate].State,
				Bean = candidate,
				Stage = phase,
				Reason = self._statuses[candidate].Reason,
			})
			local errors = dispose(self, candidate)
			if #errors > 0 then
				self._statuses[candidate].CleanupFailed = true
				self._statuses[candidate].CleanupError = table.concat(errors, "\n")
				event(self, { Event = "CleanupBlocked", Bean = candidate })
			end
		end
		log(
			self,
			"Error",
			`{name}.{phase} failed: {message}`,
			{ Bean = name, Stage = phase, Feature = self._definitions[name].Feature }
		)
	end
	for _, phase in { "Create", "Init", "Start" } do
		for _, name in order do
			if not selected[name] then
				continue
			end
			local status = self._statuses[name]
			if status.State == "Failed" or status.State == "Skipped" then
				continue
			end
			local blocked = nil
			for _, dependency in self._definitions[name].Dependencies or {} do
				local dependencyStatus = self._statuses[dependency]
				if dependencyStatus and (dependencyStatus.State == "Failed" or dependencyStatus.State == "Skipped") then
					blocked = dependency
					break
				end
			end
			if blocked then
				status.State, status.Stage, status.Reason = "Skipped", phase, `Dependency {blocked} unavailable`
				event(self, { Event = "Skipped", Bean = name, Stage = phase, Reason = status.Reason })
				continue
			end
			log(
				self,
				"Debug",
				`{name}.{phase} (attempt {if phase == "Create" then status.Attempts + 1 else status.Attempts})`
			)
			local startedAt = now(self)
			event(self, {
				Event = "LoadStarted",
				Bean = name,
				Stage = phase,
				Feature = self._definitions[name].Feature,
			})
			local ok, message = xpcall(function(): any
				if phase == "Create" then
					status.Attempts += 1
					local definition = self._definitions[name]
					local dependencies = {}
					for _, dependency in definition.Dependencies or {} do
						dependencies[dependency] = if self._values[dependency] ~= nil
							then self._values[dependency]
							else self._instances[dependency]
					end
					if definition.Inject then
						local injected = {}
						for alias, dependency in definition.Inject do
							injected[alias] = dependencies[dependency]
						end
						dependencies = injected
					end
					local entry: Entry = { Name = name, Scope = self._createScope(), Instance = nil, Alive = true }
					local childLogger = self._logger
					pcall(function()
						local child = (self._logger :: any).Child
						if type(child) == "function" then
							childLogger = (child :: (any, string) -> any)(self._logger, name)
						end
					end)
					entry.Runtime = Runtime.new(childLogger, function()
						return entry.Alive and (self._state == "Starting" or self._state == "Running")
					end, function()
						return now(self)
					end, function(record)
						record.Bean, record.Feature, record.Attempt = name, definition.Feature, status.Attempts
						if entry.Alive then
							local current = self._statuses[name]
							if record.Event == "ExecutionFailed" then
								current.RuntimeFailures = (current.RuntimeFailures or 0) + 1
								current.LastRuntimeError = record.Reason
							elseif record.Event == "GuardDisabled" then
								current.DisabledGuards = (current.DisabledGuards or 0) + 1
							end
						end
						event(self, record)
						log(
							self,
							if record.Event == "ExecutionFailed"
								then "Error"
								elseif record.Event == "GuardDisabled" then "Warn"
								else "Debug",
							record.Event,
							record
						)
					end)
					self._runtimes[name] = entry.Runtime
					table.insert(self._entries, entry)
					local instance =
						definition.Create(table.freeze(dependencies), entry.Scope, entry.Runtime :: Runtime.Runtime)
					assert(type(instance) == "table", `Factory {name} must return a table`)
					entry.Instance, self._instances[name] = instance, instance
				else
					local instance = self._instances[name]
					local callback = instance[phase]
					if type(callback) == "function" then
						(callback :: (any) -> ())(instance)
					end
				end
				return nil
			end, traceback)
			local elapsed = math.max(0, now(self) - startedAt)
			status[phase .. "Duration"] = elapsed
			event(self, {
				Event = if ok then "LoadSucceeded" else "LoadFailed",
				Bean = name,
				Feature = self._definitions[name].Feature,
				Stage = phase,
				Duration = elapsed,
				Reason = if ok then nil else tostring(message),
				Attempt = status.Attempts,
			})
			if ok then
				status.State = if phase == "Start" then "Running" else phase
				status.Started = phase == "Start"
				event(self, { Event = "StateChanged", Bean = name, State = status.State })
				log(self, "Debug", `{name}.{phase} completed`, {
					Duration = elapsed,
					Attempt = status.Attempts,
					Feature = self._definitions[name].Feature,
				})
			else
				fail(name, phase, tostring(message))
			end
		end
	end
	-- Retry may append a dependency after an already running unrelated component.
	-- Rebuild topological entry order so final teardown is still dependency-safe.
	local entries = {}
	for _, entry in self._entries do
		entries[entry.Name] = entry
	end
	table.clear(self._entries)
	for _, name in order do
		if entries[name] then
			table.insert(self._entries, entries[name])
		end
	end
	self._executing = false
end

local function retry(self: ApplicationContext): boolean
	local selected = {}
	for _, name in self._order do
		local status = self._statuses[name]
		if status and (status.State == "Failed" or status.State == "Skipped") and not status.CleanupFailed then
			-- A branch with failed cleanup cannot be safely re-created.
			local available = true
			for _, dependency in self._definitions[name].Dependencies or {} do
				local dependencyStatus = self._statuses[dependency]
				if dependencyStatus and dependencyStatus.State ~= "Running" and not selected[dependency] then
					available = false
					break
				end
			end
			if available then
				selected[name] = true
			end
		end
	end
	if next(selected) == nil then
		return false
	end
	execute(self, self._order, selected)
	return true
end

-- One explicit retry wave after startup. Failed modules restart from Create,
-- including Init/Start; skipped dependents recover in the same wave.
function ApplicationContext.RetryFailed(self: ApplicationContext): any
	assert(self._state == "Running", "RetryFailed is available only while Running")
	assert(not self._executing and not self._retrying, "ApplicationContext lifecycle is already executing")
	self._retrying = true
	event(self, { Event = "RetryRequested" })
	retry(self)
	self._retrying = false
	summary(self, "Retry")
	return self:GetStatus()
end

function ApplicationContext.Run(self: ApplicationContext): ApplicationContext
	assert(self._state == "New", "An ApplicationContext can run only once")
	self._state = "Starting"
	event(self, { Event = "ContextState", State = "Starting" })
	log(self, "Info", "Starting application context")
	local valid, order = xpcall(function(): any
		return resolveOrder(self)
	end, traceback)
	if not valid then
		self._state = "Failed"
		event(self, { Event = "ContextState", State = "Failed" })
		log(self, "Error", `Dependency validation failed: {order}`)
		log(self, "Info", "Startup FAILED: started=0 alive=0; dependency graph is invalid")
		error(order, 0)
	end
	self._order = order
	local selected = {}
	for _, name in order do
		selected[name] = true
	end
	execute(self, order, selected)
	self._state = "Running"
	event(self, { Event = "ContextState", State = "Running" })
	self._retrying = true
	for attempt = 1, self._retryAttempts do
		local status = self:GetStatus()
		if status.Failed + status.Skipped == 0 then
			break
		end
		event(self, { Event = "Retry", Attempt = attempt })
		log(self, "Info", `Retrying failed startup branches ({attempt}/{self._retryAttempts})`)
		if self._wait and self._retryDelay > 0 then
			local ok, message = pcall(self._wait, self._retryDelay)
			if not ok then
				log(self, "Error", `Retry wait failed: {message}`)
				break
			end
		end
		if self._state ~= "Running" then
			break
		end
		if not retry(self) then
			break
		end
	end
	self._retrying = false
	if self._state == "Running" then
		summary(self, "Startup")
	end
	return self
end

function ApplicationContext.Destroy(self: ApplicationContext): { string }
	if self._state == "Stopped" or self._state == "Failed" or self._state == "Stopping" then
		return {}
	end
	assert(self._state ~= "Starting" and not self._executing, "Cannot destroy a context while lifecycle is executing")
	self._state = "Stopping"
	event(self, { Event = "ContextState", State = "Stopping" })
	local errors = {}
	for index = #self._entries, 1, -1 do
		for _, message in dispose(self, self._entries[index].Name) do
			table.insert(errors, message)
		end
	end
	self._state = "Stopped"
	event(self, { Event = "ContextState", State = "Stopped" })
	for name, status in self._statuses do
		if status.State == "Running" then
			status.State = "Stopped"
			event(self, { Event = "StateChanged", State = "Stopped", Bean = name })
		end
	end
	log(self, "Info", `Stopped application context; cleanup errors: {#errors}`)
	return errors
end
return ApplicationContext
