--!strict
local Validation = require("../Utility/Validation")
local Contract = {}
local kinds: { [string]: boolean } = { String = true, Boolean = true, F64 = true, U8 = true, U32 = true }
export type Definition = {
	Name: string,
	ReceiveOn: string,
	Fields: { any },
	RateLimit: { number }?,
	Version: number?,
	Check: Validation.Check?,
	_TypeCheck: Validation.Check?,
}
function Contract.new(definition: Definition): Definition
	assert(type(definition.Name) == "string" and #definition.Name > 0, "Contract needs a name")
	assert(definition.ReceiveOn == "Server" or definition.ReceiveOn == "Client", "Invalid ReceiveOn")
	assert(definition.Check == nil or type(definition.Check) == "function", "Invalid contract Check")
	local fields: { any } = {}
	for _, field in definition.Fields do
		local copy = if type(field) == "string" then { Type = field } else table.clone(field)
		assert(kinds[copy.Type], "Unknown field type")
		if copy.MaxLength then
			assert(copy.MaxLength >= 0 and copy.MaxLength < math.huge and copy.MaxLength % 1 == 0, "Invalid MaxLength")
		end
		table.insert(fields, table.freeze(copy) :: any)
	end
	local rate = if definition.RateLimit then table.clone(definition.RateLimit) else nil
	if rate then
		assert(
			#rate == 2
				and rate[1] > 0
				and rate[1] < math.huge
				and rate[1] % 1 == 0
				and rate[2] > 0
				and rate[2] < math.huge,
			"Invalid rate limit"
		)
		table.freeze(rate)
	end
	local version = definition.Version or 1
	assert(version >= 1 and version % 1 == 0 and version < math.huge, "Invalid contract version")
	return table.freeze({
		Name = definition.Name,
		ReceiveOn = definition.ReceiveOn,
		Fields = table.freeze(fields),
		RateLimit = rate,
		Version = version,
		Check = definition.Check,
	}) :: Definition
end
function Contract.Registry(definitions: { Definition }, types: any?): { [string]: Definition }
	local result: { [string]: Definition } = {}
	for _, definition in definitions do
		local contract: Definition = Contract.new(definition)
		if types then
			local compiled = table.clone(contract)
			compiled._TypeCheck = Validation.Tuple(types, contract.Fields)
			contract = table.freeze(compiled) :: Definition
		end
		assert(result[contract.Name] == nil, `Duplicate contract: {contract.Name}`)
		result[contract.Name] = contract
	end
	return table.freeze(result)
end
function Contract.Validate(definition: Definition, values: any): (boolean, string?)
	if values.n ~= #definition.Fields then
		return false, "Argument count mismatch"
	end
	if definition._TypeCheck then
		local valid, reason = Validation.Check(definition._TypeCheck, table.unpack(values, 1, values.n))
		if not valid then
			return false, reason
		end
	end
	for index, field in definition.Fields do
		local value, kind = values[index], field.Type
		if kind == "String" then
			if type(value) ~= "string" or #value > (field.MaxLength or 65535) then
				return false, `Invalid string at {index}`
			end
		elseif kind == "Boolean" then
			if type(value) ~= "boolean" then
				return false, `Invalid boolean at {index}`
			end
		else
			if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
				return false, `Invalid number at {index}`
			end
			if kind == "U8" or kind == "U32" then
				if value % 1 ~= 0 or value < 0 or value > (if kind == "U8" then 255 else 4294967295) then
					return false, `Out of range at {index}`
				end
			end
		end
	end
	if definition.Check then
		return Validation.Check(definition.Check, table.unpack(values, 1, values.n))
	end
	return true, nil
end
-- Canonical manifest, rather than a collision-prone short hash, for compatibility checks.
function Contract.Manifest(registry: { [string]: Definition }): string
	local names, parts = {}, {}
	for name in registry do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local item = registry[name]
		table.insert(parts, string.format("%q:%s:%d", name, item.ReceiveOn, item.Version or 1))
		for _, field in item.Fields do
			table.insert(parts, `:{field.Type}:{field.MaxLength or 65535}`)
		end
		table.insert(parts, ";")
	end
	return table.concat(parts)
end
return Contract
