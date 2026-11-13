--!strict
-- Immutable module manifests and dependency visibility checks. No module scanning.
local Context = require("./Container")
local Contract = require("../Network/Contract")

type Binding = {
	Owner: string?,
	Dependencies: { string },
}

export type Definition = {
	Name: string,
	Side: string?,
	Contracts: { Contract.Definition }?,
	Imports: { string }?,
	Providers: { Context.Definition }?,
	Values: { [string]: any }?,
	Exports: { string }?,
}

local Module = {}

local function names(list: { string }?): { string }
	local result, seen = {}, {}
	for _, name in list or {} do
		assert(type(name) == "string" and #name > 0, "Expected a nonempty name")
		assert(not seen[name], `Repeated name: {name}`)
		seen[name] = true
		table.insert(result, name)
	end
	return table.freeze(result)
end

function Module.new(definition: Definition): Definition
	assert(type(definition.Name) == "string" and #definition.Name > 0, "Module needs a Name")
	local side = definition.Side or "Shared"
	assert(side == "Shared" or side == "Server" or side == "Client", "Invalid module Side")
	local providers: { Context.Definition } = {}
	for _, provider in definition.Providers or {} do
		local copy = table.clone(provider)
		if copy.Dependencies then
			copy.Dependencies = names(copy.Dependencies)
		end
		if copy.Inject then
			copy.Inject = table.freeze(table.clone(copy.Inject))
		end
		table.insert(providers, table.freeze(copy) :: Context.Definition)
	end
	local contracts = {}
	for _, definition in definition.Contracts or {} do
		table.insert(contracts, Contract.new(definition))
	end
	local snapshot: Definition = {
		Contracts = table.freeze(contracts),
		Name = definition.Name,
		Side = side,
		Imports = names(definition.Imports),
		Exports = names(definition.Exports),
		Values = table.freeze(table.clone(definition.Values or {})),
		Providers = table.freeze(providers),
	}
	return table.freeze(snapshot) :: Definition
end

function Module.Validate(modules: { Definition }, bindings: { [string]: Binding }, side: string?)
	local byName: { [string]: Definition } = {}
	local exports: { [string]: { [string]: boolean } } = {}
	local imports: { [string]: { [string]: boolean } } = {}
	for _, module in modules do
		assert(
			not side or side == "Shared" or module.Side == "Shared" or module.Side == nil or module.Side == side,
			`Module {module.Name} belongs to {module.Side}, not {side}`
		)
		assert(not byName[module.Name], `Duplicate module: {module.Name}`)
		byName[module.Name], exports[module.Name], imports[module.Name] = module, {}, {}
		for _, name in module.Exports or {} do
			assert(
				bindings[name] and bindings[name].Owner == module.Name,
				`Module {module.Name} cannot export unknown or foreign binding: {name}`
			)
			exports[module.Name][name] = true
		end
		for _, name in module.Imports or {} do
			imports[module.Name][name] = true
		end
	end
	local visiting, visited = {}, {}
	local path: { string } = {}
	local function visit(name: string)
		assert(byName[name], `Missing module: {name}`)
		assert(not visiting[name], `Module cycle: {table.concat(path, " -> ")} -> {name}`)
		if visited[name] then
			return
		end
		visiting[name] = true
		table.insert(path, name)
		for _, dependency in byName[name].Imports or {} do
			visit(dependency)
		end
		table.remove(path)
		visiting[name], visited[name] = nil, true
	end
	for _, module in modules do
		visit(module.Name)
	end
	for name, binding in bindings do
		for _, dependency in binding.Dependencies do
			local provider = bindings[dependency]
			if provider and provider.Owner and provider.Owner ~= binding.Owner then
				assert(
					exports[provider.Owner][dependency],
					`Binding {name} cannot inject private binding {dependency} from {provider.Owner}`
				)
				assert(
					not binding.Owner or imports[binding.Owner][provider.Owner],
					`Module {binding.Owner} must import {provider.Owner} to inject {dependency}`
				)
			end
		end
	end
end

return Module
