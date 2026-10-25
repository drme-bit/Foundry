"""Exercise installed dependencies and the Roblox loader without editing Packages."""
from pathlib import Path
import os
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def literal(text):
    marker = '='
    while ']' + marker + ']' in text:
        marker += '='
    return '[' + marker + '[' + text + ']' + marker + ']'

def prepare(directory):
    tmp = Path(directory)
    shutil.copytree(ROOT/'src', tmp/'src')
    shutil.copytree(ROOT/'tests/suites', tmp/'suites')
    shutil.copy(ROOT/'Packages/_Index/osyrisrblx_t@3.1.1/t/lib/init.lua', tmp/'t.luau')
    trove = (ROOT/'Packages/_Index/sleitnick_trove@1.8.0/trove/init.luau').read_text()
    boundary = (ROOT/'src/Roblox/Dependencies.luau').read_text()
    (tmp/'dependencies.luau').write_text('''--!nonstrict
local t = require("./t")
local service = {}
local troveChunk = assert(loadstring(TROVE))
setfenv(troveChunk, setmetatable({
    game = { GetService = function() return service end },
    task = { spawn = function(fn, ...) fn(...) end, cancel = function() end },
}, { __index = getfenv() }))
local Trove = troveChunk()
local count = 0
local tracked = table.clone(t)
tracked.tuple = function(...) count += 1; return t.tuple(...) end
return {
    t = tracked, Trove = Trove, Source = BOUNDARY, EnvironmentSource = ENGINE_BOUNDARY,
    Compiled = function() return count end,
}
'''.replace('TROVE', literal(trove)).replace('ENGINE_BOUNDARY', literal((ROOT/'src/Roblox/Environment.luau').read_text())).replace('BOUNDARY', literal(boundary)))
    # Replace only the engine boundary in this disposable copy with its test port.
    (tmp/'src/Roblox/Dependencies.luau').write_text('return require("../../dependencies")\n')
    (tmp/'run.luau').write_text('''--!nonstrict
local deps = require("./dependencies")
local F = require("./src")
local count = 0
local function test(name, fn) fn(); count += 1; print("PASS Dependencies: " .. name) end
test("Roblox runtime defaults are lazy and side detection uses the actual platform", function()
    for _, side in { "Server", "Client" } do
        local platform = { IsServer = function() return side == "Server" end, IsClient = function() return side == "Client" end }
        local binds, serviceReads = 0, 0
        local waitPort = function() end
        local chunk = assert(loadstring(deps.EnvironmentSource))
        setfenv(chunk, setmetatable({
            game = {
                GetService = function(_, name) assert(name == "RunService"); serviceReads += 1; return platform end,
                BindToClose = function(_, callback) binds += 1; callback() end,
            },
            task = { wait = waitPort },
        }, { __index = getfenv() }))
        local boundary = chunk()
        assert(serviceReads == 0)
        local defaults = boundary.Get()
        assert(defaults.Platform == platform and defaults.Wait == waitPort and serviceReads == 1)
        local stopped = false
        defaults.BindShutdown(function() stopped = true end)
        assert(stopped and binds == 1)
    end
end)
local function node(children)
    return { FindFirstChild = function(_, name) return children[name] end }
end
local tAlias, troveAlias, swiftAlias = {}, {}, {}
local aliases = node({ t = tAlias, Trove = troveAlias, SwiftPacket = swiftAlias })
local swift, loaded = {}, 0
local modules = { [tAlias] = deps.t, [troveAlias] = deps.Trove, [swiftAlias] = swift }
local function load(root, modules)
    local chunk = assert(loadstring(deps.Source))
    setfenv(chunk, setmetatable({
        game = {}, script = { Parent = { Parent = root } },
        require = function(reference) if reference == swiftAlias then loaded += 1 end; return assert(modules[reference]) end,
    }, { __index = getfenv() }))
    return chunk()
end
test("Wally aliases, bundled model and source layouts resolve real libraries", function()
    local wally = node({}); wally.Parent = aliases
    local bundle = node({ Packages = aliases }); bundle.Parent = node({})
    local source = node({}); source.Parent = node({ Packages = aliases })
    for _, root in { wally, bundle, source } do
        local before = loaded
        local result = load(root, modules)
        assert(loaded == before, "SwiftPacket must not load before Network needs it")
        assert(result.t == deps.t and result.Trove == deps.Trove and table.isfrozen(result))
        assert(result.GetSwiftPacket() == swift and result.GetSwiftPacket() == swift)
        assert(loaded == before + 1)
    end
end)
test("Wally-local aliases take precedence over unrelated sibling Packages", function()
    local parent = node({ t = tAlias, Trove = troveAlias, SwiftPacket = swiftAlias, Packages = node({ t = {}, Trove = {}, SwiftPacket = {} }) })
    local root = node({}); root.Parent = parent
    assert(load(root, modules).t == deps.t)
end)
test("missing Roblox dependencies fail with installation guidance", function()
    local root = node({}); root.Parent = node({})
    local ok, reason = pcall(load, root, {})
    assert(not ok and tostring(reason):find("wally install", 1, true))
end)
test("default scope owns real Trove resources and rejects additions after destroy", function()
    assert(F.t == deps.t and F.Utility.Trove == deps.Trove)
    local scope, removed, remaining = F.Scope.new(), 0, 0
    local cleaner = scope:CreateTrove()
    local first = cleaner:Add({ Destroy = function() removed += 1 end })
    cleaner:Remove(first)
    cleaner:Add({ Destroy = function() remaining += 1 end })
    assert(removed == 1 and remaining == 0)
    scope:Destroy(); scope:Destroy()
    assert(remaining == 1)
    assert(not pcall(function() scope:CreateTrove() end))
end)
test("network composition compiles bundled t without a Types argument", function()
    local incoming, received = nil, 0
    local before = deps.Compiled()
    local app = F:ServerContext({ Network = {
        Contracts = {{ Name = "Input", ReceiveOn = "Server", Fields = { "String" },
            Check = deps.t.tuple(deps.t.literal("allowed")) }},
        CreateAdapter = function() return {
            On = function(_, _, callback) incoming = callback; return { Disconnect = function() end } end,
        } end,
    } }):Start()
    assert(deps.Compiled() == before + 2)
    app:Get("Network"):On("Input", function() received += 1 end)
    incoming({}, "denied"); incoming({}, "allowed")
    assert(received == 1)
    app:Destroy()
end)
test("direct hosts also use bundled t and explicit overrides remain supported", function()
    local before = deps.Compiled()
    local definition = { Name = "Input", ReceiveOn = "Server", Fields = { "U8" } }
    local host = F.Network.Host.new({ Side = "Server", Contracts = { definition }, Adapter = {} })
    assert(deps.Compiled() == before + 1)
    host:Destroy()
    local override = table.clone(deps.t)
    local called = 0
    override.tuple = function(...) called += 1; return deps.t.tuple(...) end
    F.Network.Host.new({ Side = "Server", Types = override, Contracts = { definition }, Adapter = {} }):Destroy()
    assert(called == 1)
end)
for name, fn in require("./suites/Contexts")(F, deps.t) do
    test("installed t: " .. name, fn)
end
print("Foundry dependency integration: " .. count .. " tests passed")
''')
    return tmp/'run.luau'

if __name__ == '__main__':
    # A unique fixture is retained only for this process; the main checker supplies
    # a TemporaryDirectory and removes it after running the fixture.
    folder = tempfile.mkdtemp(prefix='foundry-deps-')
    path = prepare(folder)
    os.execvp('luau', ['luau', str(path)])
