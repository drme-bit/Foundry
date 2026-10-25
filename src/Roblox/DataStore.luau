--!nocheck
-- All engine calls, budgeting, storage limits and error classification live here.
local environment = getfenv()
local Adapter = {}
Adapter.__index = Adapter
function Adapter.new()
	assert(environment.game, "Persistence needs Roblox or an explicit Adapter")
	local game = environment.game
	assert(game:GetService("RunService"):IsServer(), "Persistence is server-only")
	return setmetatable(
		{ _service = game:GetService("DataStoreService"), _http = game:GetService("HttpService"), _stores = {} },
		Adapter
	)
end
function Adapter:CanRequest()
	local kinds = environment.Enum.DataStoreRequestType
	return self._service:GetRequestBudgetForRequestType(kinds.StandardRead) >= 1
		and self._service:GetRequestBudgetForRequestType(kinds.StandardWrite) >= 1
end
function Adapter:NewToken()
	return self._http:GenerateGUID(false)
end
function Adapter:Validate(value)
	-- Leave room below the engine's 4 MiB hard limit.
	assert(#self._http:JSONEncode(value) <= 4000000, "Persistence record exceeds storage size limit")
end
function Adapter:IsRetryable(reason)
	-- Retry only recognized transient failures; validation/configuration errors fail closed.
	local code = tonumber(tostring(reason):match("^%s*(%d%d%d)") or tostring(reason):match(":%s*(%d%d%d):"))
	return code == 0
		or (code and code >= 301 and code <= 306)
		or code == 502
		or code == 503
		or code == 504
		or code == 501
end
function Adapter:Update(name, key, transform, userIds)
	local store = self._stores[name]
	if not store then
		store = self._service:GetDataStore(name)
		self._stores[name] = store
	end
	return store:UpdateAsync(key, function(current, info)
		local updated = transform(current)
		if updated == nil then
			return nil
		end
		self:Validate(updated)
		local ids = if info then info:GetUserIds() else {}
		if userIds then
			for _, id in userIds do
				if not table.find(ids, id) then
					table.insert(ids, id)
				end
			end
		end
		return updated, ids, if info then info:GetMetadata() else {}
	end)
end
return Adapter
