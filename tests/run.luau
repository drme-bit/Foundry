--!nonstrict
local Context = require("../src/Context/Container")
-- Static requires also work in standalone Luau without Roblox or installed packages.
local suites = {
	ApplicationContext = require("./suites/ApplicationContext"),
	ApplicationContextRetry = require("./suites/ApplicationContextRetry"),
	ApplicationContextAutowire = require("./suites/ApplicationContextAutowire"),
}
local count = 0
for _, suite in { "ApplicationContext", "ApplicationContextRetry", "ApplicationContextAutowire" } do
	local cases = suites[suite](Context)
	local names = {}
	for name in cases do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		cases[name]()
		count += 1
		print(`PASS {suite}: {name}`)
	end
end
for name, case in require("./suites/Foundry")(require("../src")) do
	case()
	count += 1
	print(`PASS Foundry: {name}`)
end
for name, case in require("./suites/Diagnostics")(require("../src")) do
	case()
	count += 1
	print(`PASS Diagnostics: {name}`)
end
for name, case in require("./suites/Infrastructure")(require("../src")) do
	case()
	count += 1
	print(`PASS Infrastructure: {name}`)
end
for name, case in require("./suites/Contexts")(require("../src")) do
	case()
	count += 1
	print(`PASS Contexts: {name}`)
end
for name, case in require("./suites/Players")(require("../src")) do
	case()
	count += 1
	print(`PASS Players: {name}`)
end
for name, case in require("./suites/Shutdown")(require("../src")) do
	case()
	count += 1
	print(`PASS Shutdown: {name}`)
end
print(`Foundry: {count} tests passed`)
