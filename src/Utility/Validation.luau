--!strict
-- Validator functions follow t's (ok, reason?) contract. The library is injected.
local Validation = {}
export type Check = (...any) -> (boolean, string?)
function Validation.Check(check: any, ...: any): (boolean, string?)
	if type(check) ~= "function" then
		return false, "Validator must be a function"
	end
	local ok, accepted, reason = pcall(check, ...)
	if not ok then
		return false, `Validator failed: {tostring(accepted)}`
	end
	if accepted ~= true then
		return false, if type(reason) == "string" then reason else "Validation rejected value"
	end
	return true, nil
end
-- Compile once per contract, never construct validators per message or frame.
function Validation.Tuple(types: any, fields: { any }): Check
	assert(type(types) == "table" and type(types.tuple) == "function", "Types must provide the t interface")
	local checks: { any } = {}
	for _, field in fields do
		local kind = field.Type
		local check = if kind == "String" then types.string elseif kind == "Boolean" then types.boolean else types.number
		if kind == "U8" or kind == "U32" then
			check =
				types.intersection(types.integer, types.numberConstrained(0, if kind == "U8" then 255 else 4294967295))
		end
		assert(type(check) == "function", `Missing validator for {kind}`)
		table.insert(checks, check)
	end
	local tuple: any = types.tuple
	return tuple(table.unpack(checks))
end
return Validation
