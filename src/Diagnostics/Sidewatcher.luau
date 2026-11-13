--!strict
local Sidewatcher = {}
Sidewatcher.__index = Sidewatcher

local function copyStatus(status: any): any
	local result = table.clone(status)
	result.Beans = {}
	for name, bean in status.Beans or {} do
		result.Beans[name] = table.clone(bean)
	end
	return result
end

export type Sidewatcher = typeof(setmetatable({} :: {
	_application: any,
	_logger: any,
	_scheduler: any,
	_handle: any?,
	_ticks: number,
	_last: any?,
	_failures: number,
}, Sidewatcher))

function Sidewatcher.new(application: any, scheduler: any, logger: any): Sidewatcher
	return setmetatable({
		_application = application,
		_logger = logger,
		_scheduler = scheduler,
		_handle = nil,
		_ticks = 0,
		_last = nil,
		_failures = 0,
	}, Sidewatcher)
end

function Sidewatcher.Start(self: Sidewatcher)
	self._handle = self._scheduler:Every("Sidewatcher", 1, function()
		local ok, status = pcall(function()
			return self._application:GetStatus()
		end)
		if not ok then
			self._failures += 1
			self._logger:Error("Sidewatcher check failed", { Reason = tostring(status) })
			return
		end
		self._ticks += 1
		self._last = status
		self._logger:Info("Sidewatcher heartbeat", {
			State = self._application:GetState(),
			Alive = status.Alive,
			Failed = status.Failed,
			Skipped = status.Skipped,
			RuntimeFailures = status.RuntimeFailures,
			Revision = status.Revision,
		})
	end)
end

function Sidewatcher.GetSnapshot(self: Sidewatcher): any
	return {
		Ticks = self._ticks,
		Failures = self._failures,
		LastStatus = if self._last then copyStatus(self._last) else nil,
		Active = self._handle ~= nil and self._handle:GetStatus().State ~= "Cancelled",
	}
end

function Sidewatcher.Destroy(self: Sidewatcher)
	if self._handle then
		self._handle:Cancel()
	end
	self._handle = nil
end

return Sidewatcher
