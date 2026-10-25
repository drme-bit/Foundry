--!strict
local Value = require("../Value")
local Memory = {}
Memory.__index = Memory
function Memory.new(): any
	return setmetatable({ _stores = {} }, Memory)
end
function Memory.Update(self: any, store: string, key: string, transform: any, _userIds: any?): any
	local entries = self._stores[store]
	if not entries then
		entries = {}
		self._stores[store] = entries
	end
	local previous = entries[key]
	local updated = Value.Sync(transform, if previous == nil then nil else Value.Copy(previous))
	if updated == nil then
		return nil
	end
	entries[key] = Value.Copy(updated)
	return Value.Copy(updated)
end
function Memory.Read(self: any, store: string, key: string): any
	local entry = self._stores[store] and self._stores[store][key]
	return if entry then Value.Copy(entry) else nil
end
return Memory
