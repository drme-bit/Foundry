--!strict
local Journal = require("../Utility/Journal")
local Scheduler = {}
Scheduler.__index = Scheduler
export type Options = {
	Clock: (() -> number)?,
	FrameBudgetMs: number?,
	MaxStepsPerTick: number?,
	MaxPending: number?,
	HistoryLimit: number?,
	Pulse: any?,
	CanRun: (() -> boolean)?,
	Logger: any?,
}
type Job = {
	Id: number,
	Name: string,
	State: string,
	Due: number,
	Interval: number?,
	Cooperative: boolean,
	Callback: any,
	Steps: number,
	Duration: number,
	Error: string?,
	Release: (() -> ())?,
}
type Data = {
	_jobs: { Job },
	_next: number,
	_clock: () -> number,
	_budget: number,
	_steps: number,
	_max: number,
	_stopped: boolean,
	_stepping: boolean,
	_history: Journal.Journal,
	_connection: any?,
	_logger: any,
	_canRun: () -> boolean,
}
export type Scheduler = typeof(setmetatable({} :: Data, Scheduler))
local function time(self: Scheduler): number
	local ok, value = pcall(self._clock)
	return if ok
			and type(value) == "number"
			and value == value
			and math.abs(value) < math.huge
		then value
		else os.clock()
end
local function snapshot(job: Job): any
	return {
		Id = job.Id,
		Name = job.Name,
		State = job.State,
		Due = job.Due,
		Interval = job.Interval,
		Steps = job.Steps,
		Duration = job.Duration,
		Error = job.Error,
	}
end
local function finish(self: Scheduler, job: Job, state: string)
	if job.State == "Cancelled" or job.State == "Completed" or job.State == "Failed" then
		return
	end
	job.State = state
	self._history:Push(snapshot(job))
	local index = table.find(self._jobs, job)
	if index then
		table.remove(self._jobs, index)
	end
	job.Callback = nil
	local release = job.Release
	job.Release = nil
	if release then
		pcall(release)
	end
end
function Scheduler.new(supplied: Options?): Scheduler
	local options: Options = supplied or {}
	local budget, steps, maximum = options.FrameBudgetMs or 2, options.MaxStepsPerTick or 32, options.MaxPending or 1024
	assert(budget > 0 and budget < math.huge, "FrameBudgetMs must be positive and finite")
	assert(steps >= 1 and steps <= 4096 and steps % 1 == 0, "Invalid MaxStepsPerTick")
	assert(maximum >= 1 and maximum <= 65536 and maximum % 1 == 0, "Invalid MaxPending")
	local self = setmetatable({
		_jobs = {},
		_next = 0,
		_clock = options.Clock or os.clock,
		_budget = budget / 1000,
		_steps = steps,
		_max = maximum,
		_stopped = false,
		_stepping = false,
		_history = Journal.new(options.HistoryLimit or 128),
		_connection = nil,
		_logger = options.Logger,
		_canRun = options.CanRun or function()
			return true
		end,
	}, Scheduler) :: Scheduler
	if options.Pulse then
		self._connection = options.Pulse:Connect(function()
			self:Step()
		end)
	end
	return self
end
local function add(
	self: Scheduler,
	name: string,
	callback: any,
	delay: number,
	interval: number?,
	owner: any?,
	cooperative: boolean?
): any
	assert(not self._stopped, "Scheduler is stopped")
	assert(type(name) == "string" and #name > 0 and type(callback) == "function", "Job needs a name and callback")
	assert(delay >= 0 and delay < math.huge, "Delay must be finite and nonnegative")
	assert(#self._jobs < self._max, "Scheduler queue is full")
	self._next += 1
	local job: Job = {
		Id = self._next,
		Name = name,
		State = "Queued",
		Due = time(self) + delay,
		Interval = interval,
		Cooperative = cooperative == true,
		Callback = callback,
		Steps = 0,
		Duration = 0,
	}
	table.insert(self._jobs, job)
	local handle = {}
	-- Handle closures do not expose mutable job state.
	handle.Cancel = function()
		finish(self, job, "Cancelled")
	end
	handle.Destroy = handle.Cancel
	handle.GetStatus = function()
		return snapshot(job)
	end
	if owner then
		local remove = owner.Remove
		if type(remove) == "function" then
			job.Release = function()
				(remove :: (any, any) -> ())(owner, handle)
			end
		end
		local ok, reason = pcall(function()
			owner:Add(handle, "Destroy", handle)
		end)
		if not ok then
			finish(self, job, "Cancelled")
			error(reason, 0)
		end
	end
	return handle
end
function Scheduler.After(self: Scheduler, name: string, seconds: number, callback: any, owner: any?): any
	return add(self, name, callback, seconds, nil, owner)
end
function Scheduler.Every(self: Scheduler, name: string, seconds: number, callback: any, owner: any?): any
	assert(seconds > 0 and seconds < math.huge, "Interval must be positive and finite")
	return add(self, name, callback, seconds, seconds, owner)
end
-- A cooperative step returns false to yield until a later tick; any other result completes.
function Scheduler.Enqueue(self: Scheduler, name: string, step: any, owner: any?): any
	return add(self, name, step, 0, nil, owner, true)
end
function Scheduler.Step(self: Scheduler)
	if self._stopped or self._stepping then
		return
	end
	self._stepping = true
	local ok, reason = xpcall(function(): any
		if not self._canRun() then
			return nil
		end
		local started = time(self)
		local ready = table.clone(self._jobs)
		local count = 0
		for _, job in ready do
			if self._stopped or count >= self._steps or time(self) - started >= self._budget then
				break
			end
			if job.State ~= "Queued" or job.Due > time(self) then
				continue
			end
			count += 1
			job.State = "Running"
			local stamp = time(self)
			local success, done = xpcall(job.Callback, function(message: any)
				return debug.traceback(tostring(message), 2)
			end)
			job.Steps += 1
			job.Duration += math.max(0, time(self) - stamp)
			if job.State == "Cancelled" then
				continue
			end
			if not success then
				job.Error = tostring(done)
				finish(self, job, "Failed")
				if self._logger then
					pcall(function()
						self._logger:Error("Scheduled job failed", { Job = job.Name, Reason = job.Error })
					end)
				end
			elseif job.Interval or (job.Cooperative and done == false) then
				job.State = "Queued"
				job.Due = time(self) + (job.Interval or 0)
				-- Rotate recurring/unfinished jobs behind waiting work for fairness.
				local index = table.find(self._jobs, job)
				if index then
					table.remove(self._jobs, index)
					table.insert(self._jobs, job)
				end
			else
				finish(self, job, "Completed")
			end
		end
		return nil
	end, function(message: any)
		return debug.traceback(tostring(message), 2)
	end)
	self._stepping = false
	if not ok and self._logger then
		pcall(function()
			self._logger:Error("Scheduler tick failed", { Reason = tostring(reason) })
		end)
	end
end
function Scheduler.GetSnapshot(self: Scheduler): any
	local active = {}
	for _, job in self._jobs do
		table.insert(active, snapshot(job))
	end
	return {
		Stopped = self._stopped,
		Active = active,
		History = self._history:Snapshot(),
		FrameBudgetMs = self._budget * 1000,
	}
end
function Scheduler.Destroy(self: Scheduler)
	if self._stopped then
		return
	end
	self._stopped = true
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	for _, job in table.clone(self._jobs) do
		finish(self, job, "Cancelled")
	end
end
return Scheduler
