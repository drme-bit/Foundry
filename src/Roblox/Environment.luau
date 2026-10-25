--!nocheck
-- Engine defaults stay behind this boundary so the public API is portable.
local environment = getfenv()
local Environment = {}
function Environment.Get(): any
	if environment.game == nil then
		return nil
	end
	return {
		Platform = environment.game:GetService("RunService"),
		Wait = environment.task.wait,
		BindShutdown = function(callback)
			environment.game:BindToClose(callback)
		end,
	}
end
function Environment.Persistence(): any
	if environment.game == nil then
		return nil
	end
	local game = environment.game
	assert(game:GetService("RunService"):IsServer(), "Persistence is server-only")
	return {
		Pulse = game:GetService("RunService").Heartbeat,
		Players = game:GetService("Players"),
		Spawn = environment.task.spawn,
		Wait = environment.task.wait,
	}
end
return table.freeze(Environment)
