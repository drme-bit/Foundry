# Foundry API reference

Target: `drme-bit/foundry@0.2.0`.

[README](../README.md) · [Getting started](getting-started.md) · [Architecture](architecture.md)

## Contents

- [Public exports](#public-exports)
- [Application construction](#application-construction)
- [Application options](#application-options)
- [Beans and injection](#beans-and-injection)
- [Application methods](#application-methods)
- [Startup, retry and shutdown](#startup-retry-and-shutdown)
- [Features](#features)
- [Scopes and Trove](#scopes-and-trove)
- [Validation](#validation)
- [Runtime](#runtime)
- [Scheduler](#scheduler)
- [Logger](#logger)
- [Networking](#networking)
- [Player registry](#player-registry)
- [Player sessions](#player-sessions)
- [Server information](#server-information)
- [Signals](#signals)
- [Inspector](#inspector)
- [Low-level container](#low-level-container)

## Public exports

```luau
local Foundry = require(game:GetService("ReplicatedStorage").Packages.Foundry)
```

The installation path belongs to your project. Use public exports instead of
requiring physical implementation paths. Export tables are frozen.

| Export | Purpose |
| --- | --- |
| `ApplicationContext(options?)` | Application with automatic server/client detection |
| `ServerContext(options?)` | Independent server application |
| `ClientContext(options?)` | Independent client application |
| `Boot(options?)` | Lower-level application composition |
| `Feature(definition)` | Validated, frozen feature manifest snapshot |
| `Scope` | Ordered resource ownership |
| `Logger` | Structured logging |
| `Scheduler` | Cooperative task scheduling |
| `t` | Bundled type checker in Roblox |
| `Utility.Trove` | Bundled Trove implementation in Roblox |
| `Utility.Signal` | Synchronous, failure-isolated notifications |
| `Utility.Validation` | Protected validation and tuple compilation |
| `Validation` | Alias of Utility.Validation |
| `Network.Contract` | Wire descriptions, validation and manifests |
| `Network.Host` | Transport-independent message host |
| `Network.SwiftPacket` | Compiler/adapter for a supplied SwiftPacket library |
| `Players.Registry` | Server player-session registry |
| `Server.Info` | Server metadata and readiness |
| `Persistence.new(options)` | Standalone persistence manager |
| `Persistence.Memory.new()` | Portable in-memory storage adapter |
| `Core.ApplicationContext` | Low-level dependency/lifecycle container |
| `Core.Scope` | Alias of Scope |

Wally dependency aliases, bundled models and source checkouts are supported through
the documented layouts. Missing Roblox dependencies raise an installation error.
Standalone Luau does not automatically load engine-dependent dependencies.

Exported Luau types: Application, Options, Feature, Definition, Scope, ContextScope,
Runtime, Logger, Player, PlayerModule, ShutdownOptions, LogPort and ApplicationContext.
For example: `type App = Foundry.Application`.

## Application construction

```luau
Foundry:ApplicationContext(options?): Application
Foundry:ServerContext(options?): Application
Foundry:ClientContext(options?): Application
Foundry.Boot(options?): Application
```

ApplicationContext supports colon and dot calls. It detects Server/Client with
RunService, supplies task.wait and binds server shutdown automatically. Explicit
Platform, Wait and Shutdown options override these defaults. Outside Roblox an
explicit Platform port is required; Side cannot override the detected runtime.

Side constructors remain available and support colon and dot calls. Each call creates a separate app;
there is no global context singleton. Construction does not invoke provider
factories. Requiring your own feature modules can execute their top-level code.

Side constructors set Side, infer Network.Side and reject conflicting overrides.
Platform verifies the actual execution side through IsServer/IsClient. Supply
RunService in Roblox; omit it in portable tests. A server app does not execute
client modules remotely. Shared code does not imply replicated state.

Boot defaults to Shared and requires an explicit network side when networking is
enabled. Server-only options still require Side = "Server".

## Application options

| Field | Type / default | Contract |
| --- | --- | --- |
| `Name` | `string?` | Side constructors default to Foundry/Server or Foundry/Client |
| `Side` | `string?` | Server, Client or Shared; inferred by side constructors |
| `Platform` | `any?` | Side-check port, normally RunService |
| `Persistence` | `PersistenceOptions?` | Server-only managed stores; see [Persistence](persistence.md) |
| `Features` | `{FeatureDefinition}?` | Explicit feature manifests |
| `Providers` | `{Definition}?` | Root beans |
| `Values` | `{[string]: any}?` | Borrowed values available to features |
| `Config` | `any?` | Registered as Config when non-nil |
| `ConfigSchema` | `Check?` | Validate Config before factories |
| `Types` | `any?` | Override bundled t; useful in portable tests |
| `CreateScope` | `(() -> ContextScope)?` | Defaults to Scope.new |
| `Logger` | `LogPort?` | Defaults to a Foundry logger |
| `RetryAttempts` | integer 0..10, default 2 | Additional startup recovery waves |
| `RetryDelay` | finite number >= 0, default 1 | Seconds between recovery waves when Wait is supplied |
| `Wait` | `((number) -> ())?` | Normally task.wait; no delay without this port |
| `Clock` | `(() -> number)?` | Monotonic seconds, normally os.clock |
| `HistoryLimit` | integer 0..4096, default 512 | Lifecycle/runtime journal capacity |
| `Shutdown` | `ShutdownOptions?` | Optional server shutdown binding |
| `Scheduler` | `SchedulerOptions?` | Enable bean Scheduler |
| `Network` | `NetworkOptions?` | Enable bean Network |
| `Inspector` | `InspectorOptions?` | Enable Inspector when Enabled is true |
| `Players` | `RegistryOptions?` | Enable server bean PlayerRegistry |
| `Server` | `ServerOptions?` | Enable server bean ServerInfo |

Config and Values are borrowed. They are not automatically destroyed, persisted,
replicated or reactive. ConfigSchema does not freeze Config.

## Beans and injection

```luau
type Definition = {
    Name: string,
    Dependencies: { string }?,
    Inject: { [string]: string }?,
    Create: (deps, scope, runtime) -> any,
}
```

Name is application-wide and unique. Create must return a table. Optional Init,
Start and Destroy methods receive self, not the factory's dependency arguments.

```luau
{
    Name = "Orders",
    Inject = { Sessions = "PlayerRegistry", Rules = "OrderRules" },
    Create = function(deps, scope, runtime)
        return Orders.new(deps.Sessions, deps.Rules, scope, runtime)
    end,
}
```

Dependencies lists binding names. Inject maps constructor-local aliases to names.
If Inject is present, the factory receives the alias map; additional Dependencies
can express ordering-only requirements. The deps table is frozen, but its referenced
values are not recursively frozen.

The container owns the returned bean. Do not also add it to its scope. Scope-own
subordinate resources. Inject dependencies explicitly instead of passing the entire
context into a module merely to perform hidden runtime lookups.

## Application methods

| Method | Result / behavior |
| --- | --- |
| `Register(definition)` | Register a root bean before Start; returns app |
| `RegisterValue(name, value)` | Register a borrowed value before Start; returns app |
| `Start()` | Validate/run lifecycle; returns app |
| `Run()` | Alias of Start |
| `Get(name)` | Resolve a bean/value; reject private feature bindings |
| `GetSide()` | Server, Client or Shared |
| `GetState()` | New, Starting, Running, Stopping, Stopped or Failed |
| `GetStatus()` | Detached cached lifecycle snapshot |
| `GetGraph()` | Sorted array of `{Name, Feature?, Dependencies}` |
| `GetHistory()` | Bounded lifecycle/runtime events |
| `GetLogger()` | Application logger |
| `Inspect()` | Aggregate Inspector snapshot; no Inspector bean required |
| `Execute(name, operation, callback, ...)` | Protected operation, returns `(ok, ...results)` or `(false, reason)` |
| `RetryFailed()` | One explicit recovery wave while Running; returns status |
| `Destroy()` | Release resources; returns cleanup error strings |

Start is one-shot; late registration is forbidden. Destroy is idempotent, not a
reset for another Start, and is rejected during an executing startup lifecycle.
Running can include failed beans; inspect status rather than assuming every bean
succeeded because Start returned.

Status fields: Started, Alive, Failed, Skipped, Retried, RuntimeFailures, Revision
and Beans. Beans is keyed by name. Per-bean records may include State, Stage,
Reason, Attempts, Feature, CreateDuration, InitDuration, StartDuration, RuntimeFailures,
LastRuntimeError, DisabledGuards and cleanup errors, depending on events reached.

The context has no GetPlayer/GetServerInfo shortcuts:

```luau
local registry = app:Get("PlayerRegistry")
local session = registry:GetPlayer(userId)
local server = app:Get("ServerInfo"):GetSnapshot()
```

## Startup, retry and shutdown

Startup validates features/configuration and dependency existence/cycles, then
runs Create for available beans, Init for created beans, and Start. Dependency
order applies in every stage. Array order does not replace declared edges.

A failed branch is cleaned and its consumers are skipped; independent branches
continue. Bounded retries recreate failed/skipped branches from Create while
preserving healthy independent beans. Cleanup failures can block unsafe recreation.
RetryFailed requests another wave. Gameplay side effects are never automatically retried.

### ShutdownOptions

```luau
type ShutdownOptions = { Bind: (callback: () -> ()) -> () }
Shutdown = { Bind = function(callback) game:BindToClose(callback) end }
```

Optional, server-only. After startup finishes, Foundry binds one callback calling
Destroy. Do not register a second manual callback for the same application.
Validation/graph failures never bind. If Bind throws, created beans are cleaned and
Start raises Shutdown.Bind failed. The binder is snapshotted during construction.

Manual Destroy clears the callback's application reference. The engine callback
cannot be unregistered; later invocations are harmless. Shutdown before startup
finishes is not covered. The port does not extend Roblox's shutdown deadline or
guarantee cleanup after a process crash.

## Features

```luau
Foundry.Feature({
    Name = "Orders",
    Side = "Server", -- Shared by default
    Imports = { "Wallet" },
    Exports = { "Orders" },
    Providers = providers,
    Values = values,
    Contracts = contracts,
})
```

Feature returns a validated, frozen manifest snapshot. Boot also snapshots ordinary
manifest tables, so pre-wrapping them is optional.

- Imports names features, not bindings, and does not load modules automatically.
- Exports names bindings owned by that feature; other bindings are private.
- Foreign injection needs the binding's export and an import of its owning feature.
  Root consumers can inject exported feature bindings.
- Binding names are application-wide; duplicate names are rejected.
- Wrong-side features, import cycles, missing imports and invalid visibility fail
  before factories. Shared manifests may run on either side.
- Feature Contracts merge with Network.Contracts; duplicate names fail.

## Scopes and Trove

```luau
local scope = Foundry.Scope.new()
```

| Method | Contract |
| --- | --- |
| `Add(resource, method?, index?)` | Own and return resource |
| `Remove(index)` | Release and immediately clean an indexed resource |
| `Extend()` | Create an owned child Foundry scope |
| `CreateTrove(implementation?)` | Create an owned Trove, bundled by default in Roblox |
| `Destroy()` | Reverse-order cleanup; aggregate errors after all entries; idempotent |

Cleanup inference: invoke functions; Destroy Instances; Disconnect connections;
use Destroy or Disconnect for tables. method can be a method name or a callback
receiving the resource. Replacing an index cleans its old resource first. Add
after destruction, self-ownership and nil resources are rejected.

```luau
scope:Add(connection)
scope:Add(resource, "Close", "CurrentResource")
scope:Add(function() releaseReservation() end)
scope:Remove("CurrentResource")

local cleaner = scope:CreateTrove()
cleaner:Add(Instance.new("Part"))
scope:Destroy() -- owns cleaner:Destroy too
```

Foundry.Utility.Trove exposes the installed upstream library directly. A child
Trove is one scope entry; its internal ordering/callback behavior follows
[Trove's API](https://sleitnick.github.io/RbxUtil/api/Trove/), not Scope's ordered
guarantee. Keep order-sensitive resources in Scope:Add. Never register the same
resource with both owners.

The implementation argument supports portable tests/custom implementations.
Outside Roblox, CreateTrove without an implementation raises an availability error.

## Validation

```luau
local t = Foundry.t
local schema = t.strictInterface({ MaxOrders = t.integer })
local ok, reason = Foundry.Validation.Check(schema, { MaxOrders = 12 })
```

t is installed by Foundry, not separately by consumers. ConfigSchema is optional
and runs before factories. Roblox network hosts use bundled t by default; Types
overrides it. Portable Luau can supply Types explicitly.

```luau
type Check = (...any) -> (boolean, string?)
Foundry.Validation.Check(check, ...): (boolean, string?)
Foundry.Validation.Tuple(types, normalizedFields): Check
```

Check uses protected execution and accepts only true as success. Rejection,
invalid validators and exceptions return false with a reason. Tuple compiles t
validators from normalized `{Type = ...}` fields. Hosts compile once per contract,
not once per message. These helpers do not provide authorization or transactions.

## Runtime

The third factory argument is the bean-specific runtime:

```luau
runtime.Logger
runtime:Run(operation: string, callback, ...): (boolean, ...any)
runtime:Guard(operation: string, callback, options?): (...any) -> ()
```

Run returns protected results, including error tracebacks on failure. An inactive
runtime returns `(false, "Runtime is inactive")` without invoking the callback.
Execution events include duration.

Guard returns an event-compatible callback which discards results, resets its
consecutive error counter on success, and disables itself at FailureLimit.

| Guard option | Default | Bounds |
| --- | --- | --- |
| `FailureLimit` | 3 | Integer 1..100 |
| `Trace` | false | Also record successful invocations |

```luau
scope:Add(inputSignal:Connect(runtime:Guard("HandleInput", function(input)
    handleInput(input)
end, { FailureLimit = 3 })))
```

Guard does not own the connection. Runtime does not retry side effects, roll back
mutations, or preempt yielding/infinite callbacks. Old runtime generations become
inactive when disposed. Use app:Execute for external operations on a named bean.

## Scheduler

Enable Scheduler or call Foundry.Scheduler.new(options?). Pulse connects during
construction; there is no separate Scheduler:Start. Without Pulse, call Step manually.

| Option | Default / bounds |
| --- | --- |
| `FrameBudgetMs` | 2; positive finite milliseconds |
| `MaxStepsPerTick` | 32; integer 1..4096 |
| `MaxPending` | 1024; integer 1..65536 |
| `HistoryLimit` | 128; integer 0..4096 |
| `Clock` | os.clock; inherits application clock during composition |
| `Pulse` | Optional tick signal, normally Heartbeat |
| `Logger` | Optional; inherits application logger |
| `CanRun` | Defaults to true; Boot gates it on finished startup and Running state |

```luau
tasks:After(name, seconds, callback, ownerScope?): Handle
tasks:Every(name, seconds, callback, ownerScope?): Handle
tasks:Enqueue(name, step, ownerScope?): Handle
tasks:Step()
tasks:GetSnapshot()
tasks:Destroy()
```

After accepts finite nonnegative seconds. Every requires a positive finite interval,
with its first invocation after that interval. Enqueue continues on a later tick
only if step returns false; any other result completes it. Queue overflow raises.

Handles provide Cancel, Destroy (alias) and GetStatus. Status contains Id, Name,
State, Due, Interval, Steps, Duration and optional Error. States: Queued, Running,
Completed, Failed, Cancelled. Scheduler snapshots contain Stopped, Active, History
and FrameBudgetMs.

```luau
local job = tasks:Every("RefreshDisplay", 1, refreshDisplay, scope)
job:Cancel()
```

Budgets are checked between steps, not inside callbacks. New jobs wait for a later
tick. Unfinished/recurring jobs rotate behind waiting work. Every schedules from
completion and skips missed intervals. One failed job does not stop others;
cancellation does not undo work in flight. Reentrant Step is ignored. Destroy
disconnects Pulse and cancels jobs. Completed jobs release indexed owner entries
when Remove is supported.

## Logger

```luau
Foundry.Logger.new(name, options?): Logger
Foundry.Logger.Format(record): string
```

Options: Level (INFO), Capacity (200; integer 0..4096), Clock (os.clock), Sink
(prints Format(record) by default). Levels: DEBUG, INFO, WARN, ERROR, OFF.
SetLevel rejects unknown levels.

```luau
logger:Child(name): Logger
logger:SetLevel(level)
logger:Write(level, message, fields?)
logger:Debug(message, fields?)
logger:Info(message, fields?)
logger:Warn(message, fields?)
logger:Error(message, fields?)
logger:GetRecords(): {any}
logger:GetSinkFailures(): number
```

Children share storage/level with their parent. Records contain Name, Level,
Message, Fields, Time and Sequence. At most 32 string-keyed fields retain scalar
values; complex values become type labels. Format sorts keys and renders numeric
Duration in milliseconds. Sink exceptions increment SinkFailures without stopping
the app. Records are detached. The minimal LogPort provides Debug, Info and Error.

## Networking

### Network options

| Field | Contract |
| --- | --- |
| `Side` | Inferred by side-specific constructors |
| `Contracts` | Ordered contract definitions |
| `CreateAdapter(deps)` | Alternative transport factory |
| `Transport` | Defaults to "SwiftPacket" |
| `Library` | Optional override of the bundled SwiftPacket library |
| `PacketsBinding` | Optional explicit binding name for precompiled packets |
| `Inject` | Factory dependencies; defaults to packet binding when needed |
| `PeersRemoving` | Optional peer-removal signal to release rate-limit state |

Enabling Network selects SwiftPacket unless CreateAdapter is supplied. SwiftPacket is the bundled default. Network = { Contracts = contracts } is sufficient.
Library overrides the installed SwiftPacket implementation; an explicit PacketsBinding
selects a precompiled packet table instead. CreateAdapter selects a custom transport.
Adapters with Destroy are scope-owned.

### Contracts

```luau
{
    Name = "Rename",
    ReceiveOn = "Server", -- or Client
    Version = 1,
    Fields = { { Type = "String", MaxLength = 48 } },
    RateLimit = { 4, 2 }, -- count, seconds
    Check = Foundry.t.tuple(Foundry.t.string),
}
```

| Wire type | Values |
| --- | --- |
| `String` | MaxLength bytes, 65535 by default |
| `Boolean` | Boolean only |
| `F64` | Finite number, excluding NaN/infinities |
| `U8` | Integer 0..255 |
| `U32` | Integer 0..4294967295 |

Name must be nonempty and unique. Version defaults to 1 and is a positive finite
integer. RateLimit uses a positive integer count and positive finite seconds.
Fields accepts type strings or descriptors. Check receives positional payload
arguments, excluding the server-side sender.

```luau
Foundry.Network.Contract.new(definition): Definition
Foundry.Network.Contract.Registry(definitions, types?): {[string]: Definition}
Foundry.Network.Contract.Validate(definition, table.pack(...)): (boolean, string?)
Foundry.Network.Contract.Manifest(registry): string
```

new freezes a normalized descriptor. Registry rejects duplicates and compiles t
tuples when types is supplied. Validate requires a packed table with n and checks
exact argument count. Wire constraints remain enforced alongside t.

Manifest canonically describes names, versions, directions and fields. It is not
a handshake and cannot serialize Check callbacks. Increase Version when their
public semantics change. Preserve contract declaration and field order on both
peers. Server handlers still enforce ownership, distance and gameplay permissions.

### Host

```luau
Foundry.Network.Host.new({
    Side = "Server", Contracts = contracts, Adapter = adapter,
    Clock = os.clock, Logger = logger, PeersRemoving = players.PlayerRemoving,
    -- Types defaults to bundled t in Roblox.
})
```

| Method | Contract |
| --- | --- |
| `On(name, callback)` | Incoming channel subscription; returns Disconnect handle |
| `Send(name, packedValues, target?)` | Validate/send; invalid outgoing values raise |
| `GetPackets()` | Packet-like compatibility interfaces |
| `GetManifest()` | Canonical schema |
| `IsCompatible(manifest)` | Exact schema comparison |
| `GetSnapshot()` | Side, Stopped, Manifest, Channels |
| `Destroy()` | Disconnect listeners and release per-peer state |

Server callbacks receive `(player, ...payload)`; client callbacks receive payload
only. Only servers may target a peer. Channel snapshots contain Name, ReceiveOn,
Received, Sent, Rejected and Errors. Message bodies are not retained.

Host shares one adapter subscription per channel and isolates listener errors.
Invalid incoming payloads are dropped before handlers. It enforces per-peer limits
unless Adapter.EnforcesRateLimit is true. Scope-own On handles.

GetPackets exposes OnServerEvent/OnClientEvent:Connect for incoming channels,
Fire(...) for outgoing channels, and server-side FireClient(player, ...) where
appropriate. It does not add RPC, handshake or readiness queues.

### SwiftPacket and custom adapters

```luau
Foundry.Network.SwiftPacket.Define(library, contracts): packets
Foundry.Network.SwiftPacket.new(packets, side): adapter
```

Define preserves declaration order/rate limits and rejects client traffic sent
to client-receive channels on the server. The adapter exposes On, Send and
EnforcesRateLimit = true. Repeated compatible definitions reuse packet objects;
conflicting definitions are rejected before changing packets. The bundled library
is loaded only when an automatic Network provider is created. Destroy releases
Foundry subscriptions, not SwiftPacket's engine-lifetime shared transport.

A custom adapter provides On(name, callback), returning a disconnectable handle,
and Send(name, packedValues, target?). On supplies the server sender as its first
argument. Provide Destroy for owned resources. Set EnforcesRateLimit only if the
transport actually enforces the configured limits.

## Player registry

Enable the server bean with `Players = { Source = players, Modules = modules }`.
Direct construction: Foundry.Players.Registry.new(options).

| Option | Purpose |
| --- | --- |
| `Source` | Players-like port: GetPlayers, PlayerAdded, PlayerRemoving |
| `Modules` | Ordered module descriptors |
| `Clock` | JoinedAt clock; inherits application clock |
| `Logger` | Errors; inherits application logger |
| `Server` | Metadata for direct construction; composition uses app Server |

```luau
type PlayerModule = {
    Name: string,
    Create: (session: Player, scope: Scope) -> any,
}
```

Names are unique; factories return non-nil modules. Returned tables with Destroy
are automatically owned; do not also add them to the supplied scope. Per-player
modules do not receive automatic Init/Start calls.

| Method / property | Contract |
| --- | --- |
| `Start()` | Subscribe before enumerating existing players; one-shot |
| `GetPlayer(playerOrUserId)` | Active session or nil |
| `GetPlayers()` | New session array ordered by Index |
| `GetSnapshot()` | Count, Players (snapshots), State |
| `Changed` | Signal carrying `(event, session)` |
| `Destroy()` | Disconnect and clean all sessions |

The context starts/stops its registry automatically. Duplicate joins do not create
duplicate records. Index increases per registry and changes on reconnect. Stale
removal events cannot remove a replacement instance/session.

Changed events: Added (before modules), Character (current character changed),
Ready (modules finished, possibly Degraded), Removed (Left with cleared runtime
references). Read GetStatus rather than treating the Ready event name as success.
Callbacks are synchronous and isolated; scope-own their connections.

Module failure rolls back its scope, records an error, and lets sibling modules
and other players continue. Exit/shutdown cleans modules in reverse order. A
yielding factory returning after exit cannot publish its result; a returned
Destroy method is called. Do not keep adding resources to a closed scope.

## Player sessions

A session is a server runtime handle, not a Roblox Player and not a context bean.
Read-only-by-convention fields: UserId, Name, DisplayName, Index, JoinedAt. Names
are captured at creation; JoinedAt is monotonic clock time, not a Unix timestamp.

| Method | Result |
| --- | --- |
| `GetInstance()` | Roblox Player, nil after exit |
| `GetCharacter()` | Current character or nil |
| `GetStatus()` | Joining, Ready, Degraded or Left |
| `GetModule(name)` | Module, nil if unknown; error after Left |
| `GetServerInfo()` | Copy of attached metadata, not live health |
| `GetSnapshot()` | Detached diagnostics |
| `Destroy()` | Lifecycle operation owned by registry |

Snapshots contain UserId, Name, DisplayName, Index, JoinedAt, Status, HasCharacter,
Modules (sorted names), Errors and Server, excluding Instances and module objects.
Old character-removal events do not clear a newer character.

Ready means framework modules were constructed. It does not imply a loaded profile,
client replication readiness or a living character. Put those states in your own
modules. One player's module failure does not automatically degrade every session.

## Server information

Enable Server metadata in ServerContext. ServerInfo depends on PlayerRegistry when
enabled. Direct construction: Foundry.Server.Info.new(options, application, registry?, clock?).

Options: JobId, PlaceId, GameId, PlaceVersion, PrivateServerId, PrivateServerOwnerId,
MaxPlayers, IsStudio. Strings default to empty, numbers to 0, IsStudio to false.
Foundry does not invent Studio IDs or secretly fetch these values from game.

```luau
server:GetSnapshot()
server:SetDraining(draining: boolean, reason: string?)
server:Destroy()
```

Snapshots copy metadata and add State, ApplicationState, StartedAt, Uptime,
PlayerCount, Ready, DrainReason and Health = {Failed, Skipped, Alive}. PlayerCount
is 0 without a registry. Uptime is nonnegative and freezes on Destroy. StartedAt
uses the injected monotonic clock, not Unix time.

Ready requires Running, no failed/skipped beans, no drain override and no stop.
State reports Degraded for a Running app with failed/skipped beans. Draining only
changes reported availability: no matchmaking changes, kicks, teleports or
cross-server directory. SetDraining after Destroy is rejected.

## Signals

```luau
Foundry.Utility.Signal.new(onError?): Signal
signal:Connect(callback): Connection
signal:Fire(...)
signal:Destroy()
```

Connections expose Connected and Disconnect. Notifications run synchronously;
listener failures reach onError when supplied without stopping siblings. The
error reporter is protected too. A listener disconnected during dispatch is not
called later in that dispatch; new listeners wait for another Fire. Destroy clears
callbacks; Fire afterward does nothing, Connect is rejected. This is not a
RemoteEvent, message queue or durable event bus.

## Inspector

```luau
Inspector = {
    Enabled = runService:IsStudio(),
    Render = function(inspector, scope, scheduler)
        -- Mount your own view and scope-own its resources.
    end,
}
```

Enabled registers the bean. Render runs at Start; scheduler can be nil. Without
Render, Foundry creates no GUI, keyboard binding or diagnostic remote.

Use app:Inspect() or app:Get("Inspector"):GetSnapshot(). Fields: State, Status,
Graph, History, Logs, and available Scheduler, Network, PlayerRegistry, ServerInfo
snapshots. A logger without GetRecords contributes an empty list. Missing optional
beans are omitted. Inspector is a read-only pull interface. A server snapshot
remote or Studio plugin is an explicit consumer integration.

## Low-level container

```luau
local container = Foundry.Core.ApplicationContext.new(options)
container:Register({ Name = "Clock", Create = function() return { Now = os.clock } end })
container:Run()
local clock = container:Get("Clock")
container:Destroy()
```

This layer has no feature or built-in network/player/server composition. Options:
Name, CreateScope, Logger, RetryAttempts, RetryDelay, Wait, Clock, HistoryLimit.
Methods: Register, RegisterValue, Run, Get, GetState, GetStatus, GetHistory,
GetLogger, Execute, RetryFailed, Destroy. ReportValidationFailure is Boot's
infrastructure hook for composition diagnostics.

Utility.Journal is internal, not exported: new(capacity), Push(record), Snapshot().
Capacity is an integer 0..4096; snapshots preserve Sequence order and shallow-copy
flat Fields maps. It is bounded diagnostic storage, not a database/event store.

## Persistence API

See [Persistence](persistence.md) for store definitions, profile methods, automatic
schema reconciliation and storage guarantees. PersistenceOptions and StoreOptions
are exported Luau types. Configured stores are injectable by name.
