"""Real SwiftPacket packet/schema code with explicit server/client transport ports."""
from pathlib import Path
import shutil
import json

ROOT = Path(__file__).resolve().parent.parent

def literal(text):
    marker = '='
    while ']' + marker + ']' in text: marker += '='
    return '[' + marker + '[' + text + ']' + marker + ']'

def prepare(directory):
    tmp = Path(directory)
    shutil.copytree(ROOT/'src', tmp/'src')
    shutil.copy(ROOT/'Packages/_Index/osyrisrblx_t@3.1.1/t/lib/init.lua', tmp/'t.luau')
    sdk = ROOT/'Packages/_Index/skatingii_swiftpacket@0.1.4/swiftpacket/src'
    names = ['init', 'packet', 'schema', 'registry', 'signal', 'thread_pool', 'configuration']
    sources = '{' + ','.join('['+json.dumps(n)+']='+literal((sdk/(n+'.luau')).read_text()) for n in names) + '}'
    pair = '''--!nonstrict
local sources = SOURCES
local sides = { Server = { Definitions = {}, Started = 0 }, Client = { Definitions = {}, Started = 0 } }
local pair = { Peer = { UserId = 7 }, Transfers = 0, Rejected = 0 }
local function transfer(side, definition, target, ...)
    assert(target == nil or target == pair.Peer)
    local data, instances = definition:Serialize(...)
    assert(typeof(data) == "buffer")
    pair.Transfers += 1
    local recipient = sides[if side == "Server" then "Client" else "Server"].Definitions[definition.Name]
    assert(recipient, "Both peers must declare the contract")
    local values = table.pack(recipient:Deserialize(data, instances))
    if side == "Client" then
        if recipient.Validator and not recipient.Validator(pair.Peer, table.unpack(values, 1, values.n)) then
            pair.Rejected += 1; return
        end
        recipient.OnServerEvent:Fire(pair.Peer, table.unpack(values, 1, values.n))
    else recipient.OnClientEvent:Fire(table.unpack(values, 1, values.n)) end
end
for _, side in { "Server", "Client" } do
    local state = sides[side]
    local server, client = {}, {}
    function server.Start() state.Started += 1 end
    function client.Start() state.Started += 1 end
    function server.Register(packet) state.Definitions[packet.Name] = packet end
    function client.Register(packet) state.Definitions[packet.Name] = packet end
    function server.Broadcast(packet, _, ...) transfer("Server", packet, nil, ...) end
    function server.SendTo(peer, packet, ...) transfer("Server", packet, peer, ...) end
    function client.Send(packet, ...) transfer("Client", packet, nil, ...) end
    local cached = { server = server, client = client }
    local function spawn(callback, ...)
        local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
        local ok, reason = coroutine.resume(thread, ...)
        assert(ok, reason)
        return thread
    end
    local service = { IsServer = function() return side == "Server" end, IsStudio = function() return false end }
    local loadModule
    loadModule = function(name)
        name = name:gsub("^@self/", ""):gsub("^%./", "")
        if cached[name] then return cached[name] end
        local chunk = assert(loadstring(assert(sources[name], name), "SwiftPacket/" .. name))
        setfenv(chunk, setmetatable({
            game = { GetService = function() return service end }, script = {},
            task = { spawn = spawn, defer = spawn }, require = loadModule,
        }, { __index = getfenv() }))
        cached[name] = chunk()
        return cached[name]
    end
    pair[side] = loadModule("init")
end
pair.Sides = sides
return pair
'''.replace('SOURCES', sources)
    (tmp/'pair.luau').write_text(pair)
    (tmp/'dependencies.luau').write_text('''local pair = require("./pair")
local result = { t = require("./t"), Current = pair.Server, Loads = 0 }
result.GetSwiftPacket = function() result.Loads += 1; return result.Current end
return result
''')
    (tmp/'src/Roblox/Dependencies.luau').write_text('return require("../../dependencies")\n')
    (tmp/'run.luau').write_text('''--!nonstrict
local pair, deps = require("./pair"), require("./dependencies")
local F = require("./src")
local contracts = {
    { Name = "AutoRequest", ReceiveOn = "Server", Fields = { "String", "U8", "F64", "Boolean" }, RateLimit = { 2, 1 } },
    { Name = "AutoReply", ReceiveOn = "Client", Fields = { "U32", "String" } },
}
local options = { Contracts = contracts }
local server = F:ServerContext({ Network = options }):Start()
deps.Current = pair.Client
local client = F:ClientContext({ Network = options }):Start()
assert(options.Transport == nil and options.Library == nil and options.Side == nil)
assert(deps.Loads == 2 and pair.Sides.Server.Started == 1 and pair.Sides.Client.Started == 1)
assert(server:GetStatus().Failed == 0 and client:GetStatus().Failed == 0)
print("PASS SwiftPacket: automatic default transport on both peers without adapter or packet binding")
local request, reply = 0, 0
server:Get("Network"):On("AutoRequest", function(peer, text, index, value, flag)
    assert(peer == pair.Peer and text == "hello" and index == 7 and value == 1.25 and flag == true)
    request += 1
    server:Get("Network"):Send("AutoReply", table.pack(123456, "accepted"), peer)
end)
client:Get("Network"):On("AutoReply", function(value, text)
    assert(value == 123456 and text == "accepted"); reply += 1
end)
client:Get("Network"):Send("AutoRequest", table.pack("hello", 7, 1.25, true))
assert(request == 1 and reply == 1 and pair.Transfers == 2)
assert(pair.Sides.Server.Definitions.AutoRequest.RateLimitCount == 2)
print("PASS SwiftPacket: real packet API and native buffer schema roundtrip through transport ports")
local before = pair.Transfers
assert(not pcall(function() client:Get("Network"):Send("AutoRequest", table.pack("hello", 256, 1.25, true)) end))
assert(pair.Transfers == before)
pair.Client("AutoReply", pair.Client.U32, pair.Client.String):Fire(1, "forbidden")
assert(pair.Rejected == 1)
print("PASS SwiftPacket: invalid payload and wrong-direction client traffic are rejected")
local raw = F.Network.SwiftPacket.Define(pair.Server, contracts)
assert(raw.AutoRequest == pair.Sides.Server.Definitions.AutoRequest)
assert(not pcall(function() F.Network.SwiftPacket.Define(pair.Server, {
    { Name = "AutoRequest", ReceiveOn = "Server", Fields = { "U32" } },
}) end))
print("PASS SwiftPacket: idempotent definitions and conflicting schema protection")
-- The legacy, explicitly named precompiled-binding path remains supported.
local legacy = F:ServerContext({ Network = { Contracts = contracts, PacketsBinding = "Raw" }, Values = { Raw = raw } }):Start()
assert(legacy:GetStatus().Failed == 0)
legacy:Destroy(); server:Destroy(); client:Destroy()
raw.AutoRequest.OnServerEvent:Fire(pair.Peer, "hello", 7, 1.25, true)
assert(request == 1 and reply == 1)
print("PASS SwiftPacket: precompiled compatibility and disconnected handlers after shutdown")
print("Foundry SwiftPacket integration: 5 scenarios passed")
''')
    return tmp/'run.luau'
