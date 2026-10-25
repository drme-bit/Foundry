--!strict
-- Portable JSON-compatible values only. Copies isolate callers and callback replays.
local Value = {}
function Value.Copy(value: any): any
	local seen: { [any]: boolean } = {}
	local nodes = 0
	local function copy(item: any, depth: number): any
		nodes += 1
		assert(depth <= 32 and nodes <= 100000, "Persistence value is too complex")
		local kind = type(item)
		if kind == "string" then
			assert(utf8.len(item) ~= nil, "Persistence strings must be valid UTF-8")
			return item
		elseif kind == "number" then
			assert(item == item and math.abs(item) < math.huge, "Persistence numbers must be finite")
			return item
		elseif kind == "boolean" then
			return item
		end
		assert(kind == "table" and getmetatable(item) == nil, "Persistence requires plain serializable tables")
		assert(not seen[item], "Persistence value contains a cycle")
		seen[item] = true
		local result: any = {}
		local strings, numbers, maximum = 0, 0, 0
		for key, entry in item do
			if type(key) == "string" then
				assert(utf8.len(key) ~= nil, "Persistence keys must be valid UTF-8")
				strings += 1
			else
				assert(type(key) == "number" and key >= 1 and key % 1 == 0, "Invalid persistence table key")
				numbers += 1
				maximum = math.max(maximum, key)
			end
			result[key] = copy(entry, depth + 1)
		end
		assert(strings == 0 or numbers == 0, "Mixed persistence tables are not supported")
		assert(maximum == numbers, "Sparse persistence arrays are not supported")
		seen[item] = nil
		return result
	end
	return copy(value, 0)
end
-- Transforms and validators must not yield, including through coroutine-aware ports.
function Value.Sync(callback: any, ...: any): (any, any)
	local thread = coroutine.create(callback)
	local ok, result, reason = coroutine.resume(thread, ...)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		error("Persistence callbacks must not yield", 0)
	end
	assert(ok, tostring(result))
	return result, reason
end
return Value
