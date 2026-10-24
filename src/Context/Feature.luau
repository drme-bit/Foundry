--!strict
-- Immutable feature manifests and dependency visibility checks. No module scanning.
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

local Feature = {}

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

function Feature.new(definition: Definition): Definition
	assert(type(definition.Name) == "string" and #definition.Name > 0, "Feature needs a Name")
	local side = definition.Side or "Shared"
	assert(side == "Shared" or side == "Server" or side == "Client", "Invalid feature Side")
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

function Feature.Validate(features: { Definition }, bindings: { [string]: Binding }, side: string?)
	local byName: { [string]: Definition } = {}
	local exports: { [string]: { [string]: boolean } } = {}
	local imports: { [string]: { [string]: boolean } } = {}
	for _, feature in features do
		assert(
			not side or side == "Shared" or feature.Side == "Shared" or feature.Side == nil or feature.Side == side,
			`Feature {feature.Name} belongs to {feature.Side}, not {side}`
		)
		assert(not byName[feature.Name], `Duplicate feature: {feature.Name}`)
		byName[feature.Name], exports[feature.Name], imports[feature.Name] = feature, {}, {}
		for _, name in feature.Exports or {} do
			assert(
				bindings[name] and bindings[name].Owner == feature.Name,
				`Feature {feature.Name} cannot export unknown or foreign binding: {name}`
			)
			exports[feature.Name][name] = true
		end
		for _, name in feature.Imports or {} do
			imports[feature.Name][name] = true
		end
	end
	local visiting, visited = {}, {}
	local path: { string } = {}
	local function visit(name: string)
		assert(byName[name], `Missing feature: {name}`)
		assert(not visiting[name], `Feature cycle: {table.concat(path, " -> ")} -> {name}`)
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
	for _, feature in features do
		visit(feature.Name)
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
					`Feature {binding.Owner} must import {provider.Owner} to inject {dependency}`
				)
			end
		end
	end
end

return Feature
