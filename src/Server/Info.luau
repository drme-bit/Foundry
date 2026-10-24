--!strict
-- Server-local metadata and health. No remote calls, IDs are not fabricated in Studio.
export type Options = {
	JobId: string?,
	PlaceId: number?,
	GameId: number?,
	PlaceVersion: number?,
	PrivateServerId: string?,
	PrivateServerOwnerId: number?,
	MaxPlayers: number?,
	IsStudio: boolean?,
}
local Info = {}
Info.__index = Info
function Info.new(options: Options, application: any, registry: any, clock: (() -> number)?): any
	local now = clock or os.clock
	local metadata = {
		JobId = options.JobId or "",
		PlaceId = options.PlaceId or 0,
		GameId = options.GameId or 0,
		PlaceVersion = options.PlaceVersion or 0,
		PrivateServerId = options.PrivateServerId or "",
		PrivateServerOwnerId = options.PrivateServerOwnerId or 0,
		MaxPlayers = options.MaxPlayers or 0,
		IsStudio = options.IsStudio == true,
	}
	return setmetatable({
		_metadata = table.freeze(metadata),
		_app = application,
		_registry = registry,
		_clock = now,
		_startedAt = now(),
		_stoppedAt = nil,
		_draining = false,
		_reason = nil,
	}, Info)
end
function Info.GetSnapshot(self: any): any
	local result = table.clone(self._metadata)
	local status = self._app:GetStatus()
	local state = self._app:GetState()
	result.State = if self._stoppedAt
		then "Stopped"
		elseif self._draining then "Draining"
		elseif state == "Running" and (status.Failed > 0 or status.Skipped > 0) then "Degraded"
		else state
	result.ApplicationState = state
	result.StartedAt = self._startedAt
	result.Uptime = math.max(0, (self._stoppedAt or self._clock()) - self._startedAt)
	result.PlayerCount = if self._registry then #self._registry:GetPlayers() else 0
	result.Ready = state == "Running"
		and not self._draining
		and not self._stoppedAt
		and status.Failed == 0
		and status.Skipped == 0
	result.DrainReason = self._reason
	result.Health = { Failed = status.Failed, Skipped = status.Skipped, Alive = status.Alive }
	return result
end
function Info.SetDraining(self: any, draining: boolean, reason: string?)
	assert(not self._stoppedAt, "ServerInfo is stopped")
	assert(type(draining) == "boolean" and (reason == nil or type(reason) == "string"), "Invalid drain status")
	self._draining = draining
	self._reason = if draining then reason else nil
end
function Info.Destroy(self: any)
	if not self._stoppedAt then
		self._stoppedAt = self._clock()
	end
end
return Info
