--!strict
-- Explicit execution boundary for owned callbacks. It never retries side effects.
type Data = { Logger: any, _active: () -> boolean, _now: () -> number, _report: (any) -> () }
local Runtime = {}
Runtime.__index = Runtime
export type Runtime = typeof(setmetatable({} :: Data, Runtime))
function Runtime.new(logger: any, active: () -> boolean, now: () -> number, report: (any) -> ()): Runtime
	return setmetatable({ Logger = logger, _active = active, _now = now, _report = report }, Runtime)
end
local function execute(self: Runtime, operation: string, callback: any, trace: boolean, ...: any): (boolean, ...any)
	assert(type(operation) == "string" and #operation > 0, "Operation needs a name")
	assert(type(callback) == "function", "Operation needs a callback")
	if not self._active() then
		return false, "Runtime is inactive"
	end
	local start = self._now()
	if trace then
		self._report({ Event = "ExecutionStarted", Operation = operation })
	end
	local result = table.pack(xpcall(callback, function(message: any): string
		return debug.traceback(tostring(message), 2)
	end, ...))
	local elapsed = math.max(0, self._now() - start)
	if trace or not result[1] then
		self._report({
			Event = if result[1] then "ExecutionSucceeded" else "ExecutionFailed",
			Operation = operation,
			Duration = elapsed,
			Reason = if result[1] then nil else tostring(result[2]),
		})
	end
	return table.unpack(result, 1, result.n)
end
function Runtime.Run(self: Runtime, operation: string, callback: any, ...: any): (boolean, ...any)
	return execute(self, operation, callback, true, ...)
end

function Runtime.Guard(
	self: Runtime,
	operation: string,
	callback: any,
	options: { FailureLimit: number?, Trace: boolean? }?
): (...any) -> ()
	assert(type(operation) == "string" and #operation > 0, "Operation needs a name")
	assert(type(callback) == "function", "Operation needs a callback")
	local limit = if options and options.FailureLimit then options.FailureLimit else 3
	assert(limit >= 1 and limit <= 100 and limit % 1 == 0, "FailureLimit must be an integer from 1 to 100")
	local failures, disabled = 0, false
	return function(...: any)
		if disabled or not self._active() then
			return
		end
		local ok = execute(self, operation, callback, options ~= nil and options.Trace == true, ...)
		failures = if ok then 0 else failures + 1
		if failures >= limit then
			disabled = true
			self._report({ Event = "GuardDisabled", Operation = operation, Failures = failures })
		end
	end
end
return Runtime
