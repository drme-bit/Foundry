--!strict
local Boot = require("./Boot")
local Container = require("./Container")

export type CreateApplication = (Boot.Options) -> Boot.Application
type Data = {
	_options: Boot.Options,
	_create: CreateApplication,
	_application: Boot.Application?,
}

local Builder = {}
Builder.__index = Builder
export type Builder = typeof(setmetatable({} :: Data, Builder))

local infrastructure = {
	Persistence = true,
	Scheduler = true,
	Network = true,
	Inspector = true,
	Players = true,
	Server = true,
}

local function list<T>(source: { T }?): { T }
	return table.clone(source or {})
end

function Builder.new(create: CreateApplication, supplied: Boot.Options?): Builder
	return setmetatable({
		_options = table.clone(supplied or ({} :: Boot.Options)),
		_create = create,
		_application = nil,
	}, Builder) :: Builder
end

function Builder.Provider(self: Builder, definition: Container.Definition): Builder
	assert(not self._application, "Builder is already built")
	local providers = list(self._options.Providers)
	table.insert(providers, definition)
	self._options.Providers = providers
	return self
end

function Builder.Module(self: Builder, definition: any): Builder
	assert(not self._application, "Builder is already built")
	local modules = list(self._options.Modules)
	table.insert(modules, definition)
	self._options.Modules = modules
	return self
end

function Builder.Value(self: Builder, name: string, value: any): Builder
	assert(not self._application, "Builder is already built")
	assert(type(name) == "string" and #name > 0, "Value needs a name")
	local values = table.clone(self._options.Values or {})
	assert(values[name] == nil, `Duplicate value: {name}`)
	values[name] = value
	self._options.Values = values
	return self
end

function Builder.Name(self: Builder, name: string): Builder
	assert(not self._application, "Builder is already built")
	assert(type(name) == "string" and #name > 0, "Name needs a nonempty string")
	self._options.Name = name
	return self
end

function Builder.Logger(self: Builder, logger: any): Builder
	assert(not self._application, "Builder is already built")
	self._options.Logger = logger
	return self
end

function Builder.Config(self: Builder, config: any): Builder
	assert(not self._application, "Builder is already built")
	self._options.Config = config
	return self
end

function Builder.ConfigSchema(self: Builder, schema: any): Builder
	assert(not self._application, "Builder is already built")
	self._options.ConfigSchema = schema
	return self
end

function Builder.Shutdown(self: Builder, options: Boot.ShutdownOptions): Builder
	assert(not self._application, "Builder is already built")
	self._options.Shutdown = options
	return self
end

function Builder.Use(self: Builder, name: string, configuration: any?): Builder
	assert(not self._application, "Builder is already built")
	assert(infrastructure[name], `Unknown infrastructure: {name}`)
	local options = self._options :: any
	assert(options[name] == nil, `Infrastructure already configured: {name}`)
	options[name] = configuration or {}
	return self
end

function Builder.Options(self: Builder, patch: Boot.Options): Builder
	assert(not self._application, "Builder is already built")
	local options = self._options :: any
	for name, value in (patch :: any) do
		options[name] = value
	end
	return self
end

function Builder.Build(self: Builder): Boot.Application
	assert(not self._application, "Builder is already built")
	local application = self._create(self._options)
	self._application = application
	return application
end

function Builder.Start(self: Builder): Boot.Application
	local application
	if self._application then
		application = self._application
	else
		application = self:Build()
	end
	return application:Start()
end

return Builder
