--!strict
local Value = require("./Value")
local Schema = {}
Schema.__index = Schema
local function sorted(fields: any): { string }
	local keys = {}
	for key in fields do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end
local function identity(shape: any): string
	if shape.Kind == "Object" then
		local parts = { "O{" }
		for _, key in sorted(shape.Fields) do
			table.insert(parts, `{#key}:{key}={identity(shape.Fields[key])};`)
		end
		table.insert(parts, "}")
		return table.concat(parts)
	elseif shape.Kind == "Array" then
		return `A[{identity(shape.Item)}]`
	end
	assert(
		shape.Kind == "Table" or shape.Kind == "number" or shape.Kind == "string" or shape.Kind == "boolean",
		"Invalid persisted shape"
	)
	return shape.Kind
end
local function describe(value: any): any
	if type(value) ~= "table" then
		return { Kind = type(value) }
	end
	if next(value) == nil then
		return { Kind = "Table" }
	end
	if type((next(value))) == "number" then
		local item = describe(value[1])
		for _, entry in value do
			assert(identity(describe(entry)) == identity(item), "Defaults arrays must have one item shape")
		end
		return { Kind = "Array", Item = item }
	end
	local fields = {}
	for key, entry in value do
		fields[key] = describe(entry)
	end
	return { Kind = "Object", Fields = fields }
end
local function compatible(old: any, new: any, path: string)
	if old.Kind == "Table" then
		assert(new.Kind == "Table" or new.Kind == "Object" or new.Kind == "Array", `Incompatible shape at {path}`)
		return
	end
	assert(old.Kind == new.Kind, `Incompatible shape at {path}`)
	if old.Kind == "Object" then
		for key, child in old.Fields do
			assert(new.Fields[key], `Removed field at {path}.{key}; retain it or declare RenamedFrom`)
			compatible(child, new.Fields[key], `{path}.{key}`)
		end
	elseif old.Kind == "Array" then
		compatible(old.Item, new.Item, `{path}[]`)
	end
end
local function fill(data: any, defaults: any): any
	if type(defaults) ~= "table" then
		assert(type(data) == type(defaults), "Persistence field changed type")
		return data
	end
	assert(type(data) == "table", "Expected a persistence table")
	if next(defaults) == nil then
		return data
	end
	if type((next(defaults))) == "number" then
		for index, entry in data do
			assert(type(index) == "number", "Expected persistence array")
			data[index] = fill(entry, defaults[1])
		end
	else
		for key, entry in data do
			assert(type(key) == "string" and defaults[key] ~= nil, `Unknown persistence field: {tostring(key)}`)
			data[key] = fill(entry, defaults[key])
		end
		for key, entry in defaults do
			if data[key] == nil then
				data[key] = Value.Copy(entry)
			end
		end
	end
	return data
end
function Schema.new(config: any): any
	assert(type(config.Defaults) == "table", "Store requires Defaults")
	local defaults = Value.Copy(config.Defaults)
	for key in defaults do
		assert(type(key) == "string", "Root Defaults must be an object")
	end
	local shape = { Kind = "Object", Fields = {} :: any }
	for key, entry in defaults do
		shape.Fields[key] = describe(entry)
	end
	local id = identity(shape)
	assert(#id <= 32768, "Persistence schema is too large")
	local renamed = Value.Copy(config.RenamedFrom or {})
	local sources = {}
	for target, source in renamed do
		assert(
			type(target) == "string" and type(source) == "string" and target ~= source and defaults[target] ~= nil,
			"Invalid RenamedFrom"
		)
		assert(defaults[source] == nil and not sources[source], "Ambiguous RenamedFrom")
		sources[source] = true
	end
	assert(config.Schema == nil or type(config.Schema) == "function", "Schema must be a validator")
	local self =
		setmetatable({ Defaults = defaults, Shape = shape, Id = id, Check = config.Schema, Renamed = renamed }, Schema)
	self:Validate(defaults)
	return self
end
local function matches(shape: any, data: any)
	if shape.Kind == "Table" then
		assert(type(data) == "table", "Corrupt persisted table")
		return
	end
	if shape.Kind == "Object" then
		assert(type(data) == "table", "Corrupt persisted object")
		for key, child in shape.Fields do
			assert(data[key] ~= nil, `Missing persisted field: {key}`)
			matches(child, data[key])
		end
		for key in data do
			assert(shape.Fields[key] ~= nil, "Unexpected persisted field")
		end
	elseif shape.Kind == "Array" then
		assert(type(data) == "table", "Corrupt persisted array")
		for key, child in data do
			assert(type(key) == "number", "Corrupt array key")
			matches(shape.Item, child)
		end
	else
		assert(type(data) == shape.Kind, "Corrupt persisted field type")
	end
end
function Schema.Validate(self: any, data: any): any
	local copy = Value.Copy(data)
	matches(self.Shape, copy)
	local completed = fill(copy, self.Defaults)
	if self.Check then
		local accepted, reason = Value.Sync(self.Check, completed)
		assert(accepted == true, `Persistence validation failed: {tostring(reason)}`)
	end
	return completed
end
function Schema.Upgrade(self: any, stored: any, data: any): (any, boolean)
	local previous = Value.Copy(stored)
	assert(type(previous.Id) == "string" and type(previous.Shape) == "table", "Missing persisted schema")
	assert(identity(previous.Shape) == previous.Id, "Corrupt persisted schema identity")
	assert(previous.Shape.Kind == "Object", "Invalid root persisted schema")
	local result = Value.Copy(data)
	assert(type(result) == "table", "Invalid persisted payload")
	matches(previous.Shape, result)
	for target, source in self.Renamed do
		if previous.Shape.Fields[source] then
			assert(previous.Shape.Fields[target] == nil and result[target] == nil, "Ambiguous persisted rename")
			previous.Shape.Fields[target] = previous.Shape.Fields[source]
			previous.Shape.Fields[source] = nil
			result[target], result[source] = result[source], nil
		end
	end
	compatible(previous.Shape, self.Shape, "Data")
	return self:Validate(fill(result, self.Defaults)), stored.Id ~= self.Id
end
return Schema
