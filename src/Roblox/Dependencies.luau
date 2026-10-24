--!nocheck
--!nolint DeprecatedApi
-- Roblox-only dependency boundary. Portable Luau has no engine or installed packages.
local environment = getfenv()
local libraries: { t: any, Trove: any } = { t = nil, Trove = nil }
if environment.game == nil then
	return table.freeze(libraries)
end

local root = environment.script.Parent.Parent
local candidates = {}
local function candidate(container)
	if container then
		table.insert(candidates, container)
	end
end
-- Wally puts dependency aliases next to the installed Foundry module.
candidate(root.Parent)
-- The standalone model bundles its own Packages folder.
candidate(root:FindFirstChild("Packages"))
-- Source checkouts can mount Foundry and Packages beside one another.
if root.Parent then
	candidate(root.Parent:FindFirstChild("Packages"))
end
for _, container in candidates do
	local types = container:FindFirstChild("t")
	local trove = container:FindFirstChild("Trove")
	if types and trove then
		libraries.t, libraries.Trove = require(types), require(trove)
		return table.freeze(libraries)
	end
end
error(
	"Foundry dependencies are missing. Run wally install and mount the generated Packages folder, or use the bundled model."
)
