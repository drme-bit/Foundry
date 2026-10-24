--!strict
local Journal = require("../Utility/Journal")
local ranks: { [string]: number } = { DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40, OFF = math.huge }
export type Options = {
	Level: string?,
	Capacity: number?,
	Clock: (() -> number)?,
	Sink: ((any) -> ())?,
}
type Store = {
	Level: number,
	Journal: Journal.Journal,
	Clock: () -> number,
	Sink: (any) -> (),
	SinkFailures: number,
}
local Logger = {}
Logger.__index = Logger
export type Logger = typeof(setmetatable({} :: { _name: string, _store: Store }, Logger))

function Logger.Format(record: any): string
	local parts = {}
	local keys = {}
	for key in record.Fields or {} do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in keys do
		local value = record.Fields[key]
		local display = if key == "Duration" and type(value) == "number"
			then string.format("%.2fms", value * 1000)
			else tostring(value)
		table.insert(parts, `{key}={display}`)
	end
	local suffix = if #parts > 0 then " | " .. table.concat(parts, " ") else ""
	return `[{record.Name}] [{record.Level}] {record.Message}{suffix}`
end
function Logger.new(name: string, supplied: Options?): Logger
	local options: Options = supplied or {}
	local level = options.Level or "INFO"
	assert(ranks[level], `Unknown logging level: {level}`)
	return setmetatable({
		_name = name,
		_store = {
			Level = ranks[level],
			Journal = Journal.new(options.Capacity or 200),
			Clock = options.Clock or os.clock,
			SinkFailures = 0,
			Sink = options.Sink or function(record)
				print(Logger.Format(record))
			end,
		},
	}, Logger)
end
function Logger.Child(self: Logger, name: string): Logger
	return setmetatable({ _name = self._name .. "/" .. name, _store = self._store }, Logger)
end
function Logger.SetLevel(self: Logger, level: string)
	assert(ranks[level], `Unknown logging level: {level}`)
	self._store.Level = ranks[level]
end
function Logger.Write(self: Logger, level: string, message: string, fields: any?)
	local rank = ranks[level]
	if not rank or rank < self._store.Level or level == "OFF" then
		return
	end
	local safeFields = {}
	local count = 0
	if type(fields) == "table" then
		for key, value in fields do
			if type(key) == "string" and count < 32 then
				local kind = type(value)
				safeFields[key] = if kind == "string"
						or kind == "number"
						or kind == "boolean"
					then value
					else `[{kind}]`
				count += 1
			end
		end
	end
	local ok, stamp = pcall(self._store.Clock)
	local record = self._store.Journal:Push({
		Name = self._name,
		Level = level,
		Message = message,
		Fields = safeFields,
		Time = if ok
				and type(stamp) == "number"
				and stamp == stamp
				and math.abs(stamp) < math.huge
			then stamp
			else os.clock(),
	})
	if not pcall(self._store.Sink, record) then
		self._store.SinkFailures += 1
	end
end
function Logger.Debug(self: Logger, message: string, fields: any?)
	self:Write("DEBUG", message, fields)
end
function Logger.Info(self: Logger, message: string, fields: any?)
	self:Write("INFO", message, fields)
end
function Logger.Warn(self: Logger, message: string, fields: any?)
	self:Write("WARN", message, fields)
end
function Logger.Error(self: Logger, message: string, fields: any?)
	self:Write("ERROR", message, fields)
end
function Logger.GetRecords(self: Logger): { any }
	return self._store.Journal:Snapshot()
end
function Logger.GetSinkFailures(self: Logger): number
	return self._store.SinkFailures
end
return Logger
