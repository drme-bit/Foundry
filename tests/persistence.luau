--!nonstrict
local count = 0
for name, case in require("./suites/Persistence")(require("../src")) do
	case()
	count += 1
	print("PASS " .. name)
end
print(`Persistence: {count} scenarios passed`)
