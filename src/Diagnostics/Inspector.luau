--!strict
-- Pull-only, read-only diagnostic interface. No network or control commands.
local Inspector = {}
Inspector.__index = Inspector
function Inspector.new(application: any)
	return setmetatable({ _application = application }, Inspector)
end
function Inspector.GetSnapshot(self: any): any
	local app = self._application
	local okLogs, logs = pcall(function()
		local logger = app:GetLogger()
		local read = logger and logger.GetRecords
		return if type(read) == "function" then (read :: (any) -> any)(logger) else {}
	end)
	local result = {
		Logs = if okLogs then logs else {},
		State = app:GetState(),
		Status = app:GetStatus(),
		Graph = app:GetGraph(),
		History = app:GetHistory(),
	}
	for _, name in { "Scheduler", "Network", "PlayerRegistry", "ServerInfo" } do
		local ok, instance = pcall(function()
			return app:Get(name)
		end)
		if ok and type(instance.GetSnapshot) == "function" then
			result[name] = (instance.GetSnapshot :: (any) -> any)(instance)
		end
	end
	return result
end
return Inspector
