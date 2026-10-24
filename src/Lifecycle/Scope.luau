--!strict
-- Ordered ownership. Optional Roblox cleaners are supplied by the dependency boundary.
local Dependencies = require("../Roblox/Dependencies")
type Entry = { Resource: any, Cleanup: () -> (), Index: any? }
type State = { _destroyed: boolean, _entries: { Entry }, _indices: { [any]: Entry } }
local Scope = {}
Scope.__index = Scope
export type Scope = typeof(setmetatable({} :: State, Scope))

function Scope.new(): Scope
	return setmetatable({ _destroyed = false, _entries = {}, _indices = {} }, Scope)
end

local function cleanupFor(resource: any, method: any?): () -> ()
	if type(method) == "function" then
		return function()
			(method :: (any) -> ())(resource)
		end
	end
	if method == nil then
		if type(resource) == "function" then
			return resource
		end
		local kind: string = typeof(resource)
		if kind == "RBXScriptConnection" then
			method = "Disconnect"
		elseif kind == "Instance" then
			method = "Destroy"
		elseif type(resource) == "table" then
			method = if type(resource.Destroy) == "function" then "Destroy" else "Disconnect"
		end
	end
	assert(type(method) == "string", "Supply a cleanup callback or method for this resource")
	local callback = resource[method]
	assert(type(callback) == "function", `Missing cleanup method: {method}`)
	return function()
		(callback :: (any) -> ())(resource)
	end
end

function Scope.Remove(self: Scope, index: any)
	local entry = self._indices[index]
	if not entry then
		return
	end
	self._indices[index] = nil
	local position = table.find(self._entries, entry)
	if position then
		table.remove(self._entries, position)
	end
	entry.Cleanup()
end

function Scope.Add<T>(self: Scope, resource: T, method: any?, index: any?): T
	assert(not self._destroyed, "Cannot add resources to a destroyed scope")
	assert(resource ~= nil and resource ~= self, "Cannot own nil or the scope itself")
	local cleanup = cleanupFor(resource, method)
	if index ~= nil then
		self:Remove(index)
		-- A replacement's cleanup may have destroyed this scope.
		assert(not self._destroyed, "Scope was destroyed during replacement")
	end
	local entry = { Resource = resource, Cleanup = cleanup, Index = index }
	table.insert(self._entries, entry)
	if index ~= nil then
		self._indices[index] = entry
	end
	return resource
end

function Scope.Extend(self: Scope): Scope
	return self:Add(Scope.new())
end

-- Trove keeps its own cleanup semantics; the ordered scope owns it as one resource.
function Scope.CreateTrove(self: Scope, implementation: any?): any
	assert(not self._destroyed, "Cannot add resources to a destroyed scope")
	local library: any = implementation or Dependencies.Trove
	assert(
		library and type(library.new) == "function",
		"Trove is unavailable outside Roblox; supply its implementation explicitly"
	)
	local create: any = library.new
	return self:Add(create(), "Destroy")
end

function Scope.Destroy(self: Scope)
	if self._destroyed then
		return
	end
	self._destroyed = true
	local entries = self._entries
	self._entries, self._indices = {}, {}
	local errors = {}
	for i = #entries, 1, -1 do
		local ok, message = pcall(entries[i].Cleanup)
		if not ok then
			table.insert(errors, tostring(message))
		end
	end
	if #errors > 0 then
		error(table.concat(errors, "\n"), 0)
	end
end

return Scope
