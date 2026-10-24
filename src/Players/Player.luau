--!strict
-- A server session handle; profile/gameplay state belongs to per-player modules.
local Scope = require("../Lifecycle/Scope")
local Player = {}
Player.__index = Player
export type Player = typeof(setmetatable(
	{} :: {
		UserId: number,
		Name: string,
		DisplayName: string,
		Index: number,
		JoinedAt: number,
		_instance: any,
		_character: any,
		_status: string,
		_modules: { [string]: any },
		_errors: { [string]: string },
		_scope: Scope.Scope,
		_server: any,
	},
	Player
))
function Player.new(instance: any, index: number, now: number, server: any): Player
	return setmetatable({
		UserId = instance.UserId,
		Name = instance.Name,
		DisplayName = instance.DisplayName,
		Index = index,
		JoinedAt = now,
		_instance = instance,
		_character = instance.Character,
		_status = "Joining",
		_modules = {},
		_errors = {},
		_scope = Scope.new(),
		_server = server,
	}, Player)
end
function Player.GetInstance(self: Player): any
	return self._instance
end
function Player.GetCharacter(self: Player): any
	return self._character
end
function Player.GetStatus(self: Player): string
	return self._status
end
function Player.GetModule(self: Player, name: string): any
	assert(self._status ~= "Left", "Player session has ended")
	return self._modules[name]
end
function Player.GetServerInfo(self: Player): any
	return table.clone(self._server)
end
function Player.GetSnapshot(self: Player): any
	local modules = {}
	for name in self._modules do
		table.insert(modules, name)
	end
	table.sort(modules)
	return {
		UserId = self.UserId,
		Name = self.Name,
		DisplayName = self.DisplayName,
		Index = self.Index,
		JoinedAt = self.JoinedAt,
		Status = self._status,
		HasCharacter = self._character ~= nil,
		Modules = modules,
		Errors = table.clone(self._errors),
		Server = self:GetServerInfo(),
	}
end
function Player.Destroy(self: Player)
	if self._status == "Left" then
		return
	end
	self._status, self._character, self._instance = "Left", nil, nil
	local ok, reason = pcall(function()
		self._scope:Destroy()
	end)
	table.clear(self._modules)
	if not ok then
		error(reason, 0)
	end
end
return Player
