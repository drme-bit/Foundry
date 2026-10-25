# Persistence

Foundry owns the storage lifecycle. Developers declare defaults and an optional
`t` validator; they do not assign database versions or write migration chains.
Persistence is server-only and opt-in. It does not serialize the context, providers,
functions, Instances, connections or client state.

## Configure a store

```luau
local Foundry = require(game:GetService("ReplicatedStorage").Packages.Foundry)
local t = Foundry.t

local context = Foundry:ApplicationContext({
    Persistence = {
        Stores = {
            Profiles = {
                Defaults = {
                    Coins = 0,
                    Inventory = {},
                    Settings = { MusicEnabled = true },
                },
                Schema = t.strictInterface({
                    Coins = t.integer,
                    Inventory = t.array(t.string),
                    Settings = t.strictInterface({ MusicEnabled = t.boolean }),
                }),
            },
        },
    },
    Providers = {
        {
            Name = "PlayerProgress",
            Inject = { Profiles = "Profiles" },
            Create = function(deps)
                return { Profiles = deps.Profiles }
            end,
        },
    },
}):Start()
```

The `Persistence` bean owns the manager. Each store is also registered under its
name and can be injected directly. Store names must not collide with other beans.
Server runtime defaults supply DataStoreService, Heartbeat, task scheduling,
PlayerRemoving, GUIDs and the context's shutdown hook. No network replication is
automatic: publish only appropriate profile fields through your network contracts.

## Use a profile

```luau
local profiles = context:Get("Profiles")
local profile, reason = profiles:LoadPlayer(player)
if not profile then
    warn("Profile unavailable:", reason)
    return -- Do not enable gameplay that can modify this player's progress.
end

local accepted, updateError = profile:Update(function(data)
    data.Coins += 25
    table.insert(data.Inventory, "Pizza")
    return data
end)
if not accepted then
    warn("Profile update rejected:", updateError)
end

local snapshot = profile:Get() -- A detached copy, not live mutable state.
print(snapshot.Coins)

local saved, saveError = profile:Save() -- Optional explicit checkpoint.
if not saved then
    warn("Checkpoint not confirmed:", saveError)
end
```

`LoadPlayer` uses `User_{UserId}`, associates the UserId with the DataStore entry,
and releases the loaded profile when that player leaves. Loading a profile is
explicit; Foundry does not load every configured store for every connected player.
A player leaving while loading cancels publication and attempts to release the
acquired profile. A failed load never returns a writable default profile.

`Load(key, userId?)` supports other records such as a pizzeria. An associated
UserId opts that session into player-exit cleanup. Call `Release()` when an
unassociated record is no longer needed. Two loads of the same active key within
one manager return the same profile, provided the associated owner matches.

## Automatic schema identities

The persisted envelope contains an internal format marker, a canonical schema
identity and description, a per-record schema revision, a write revision and a
session lease. Foundry writes these fields; application code only works with Data.
Schema identities describe the structure and primitive types in Defaults. They
are deterministic across servers and independent of table iteration order. A new
record starts at schema revision 1; an accepted structural change advances that
record's schema revision when it is next loaded.

Foundry upgrades compatible records as part of the same UpdateAsync that acquires
the lease. Existing values survive; newly added fields receive copied defaults.
Nested objects and homogeneous nonempty arrays are supported. Changing a default
value alone does not reset an existing value or create a new schema identity.

An empty default table describes an unconstrained table. Use a `t` validator to
constrain its runtime contents. Nonempty array defaults describe the shape of all
array entries; defaults themselves are also the initial value of a new field.

Validator functions are opaque. Foundry cannot fingerprint arbitrary `t` functions
or infer intent from a rename, deletion, unit conversion or type change. Changes
to validation rules are checked against loaded data but do not independently
change the structural identity. Do not use a function's address or source text as
a database version. Additive structural changes are automatic; incompatible
changes fail closed without writing defaults over the original record.

### Renaming a field

Declare a top-level alias instead of writing a version number:

```luau
Profiles = {
    Defaults = { Coins = 0, Inventory = {} },
    RenamedFrom = { Coins = "Money" },
}
```

The old value and its type description move from Money to Coins. Keep this alias
while older records may still exist. Conflicting source/target fields, ambiguous
aliases, removed fields and incompatible types are rejected. Nested aliases and
arbitrary converters are not part of this API. A server using an older structural
schema cannot overwrite an upgraded record that contains fields it does not know.
This protection cannot distinguish different business rules expressed by validators
with the same structural defaults.

Malformed envelopes, missing persisted fields, unknown format markers, invalid
values and failed validators are rejected before an upgrade is committed. Existing
raw DataStore records from another library are not adopted implicitly.

## Save and concurrency semantics

Profiles are buffered in server memory and saved periodically, at explicit
checkpoints, on associated-player exit and on context shutdown. Clean profiles are
also periodically saved to renew their leases. Initial save times and recurring
intervals are staggered. Roblox runs due saves independently across keys so one
slow request does not hold up every other profile.

Each key has one ordered in-flight request. A session token and an expiring lease
exclude other servers. Every write checks the token, lease and expected revision;
a stale owner cannot overwrite a newer session. Once ownership is lost or the lease
expires, gameplay updates are rejected. Lock conflicts return a load failure rather
than stealing an active lease. Locks left by a crashed server expire naturally.

A stable operation token makes callback replays and retries of a committed-but-
unconfirmed write idempotent. An uncertain write is retained across Save calls and
confirmed before a newer snapshot can be sent. If an edit occurs during a save,
that newer edit remains dirty. A successful Save may confirm an earlier pending
snapshot; check GetStatus().Dirty or save again before treating a later edit as
confirmed. Release confirms outstanding work and then saves the final snapshot.

Transforms and validators must be synchronous and side-effect free. They must not
yield. Updates are validated on detached copies, so a rejected transform cannot
partially modify the live profile. Tables must be JSON-compatible: valid UTF-8,
finite numbers, booleans, plain objects or dense arrays. Cycles, mixed-key tables,
sparse arrays, metatables and excessively deep/large structures are rejected.

The Roblox adapter checks both standard read and write request budgets before
issuing UpdateAsync, preserves entry metadata/UserIds, and checks serialized size
with room below the engine's hard limit. Recognized transient errors receive
bounded exponential backoff with jitter. Configuration/validation failures, API
access being disabled and DataModel shutdown errors do not retry within a request.
An explicit later Save or periodic checkpoint may attempt another request.

There is no default-data fallback after a storage outage. A failed save retains
its in-memory data and reports the error. No system can guarantee a final save
after process termination. Shutdown waits for concurrent releases up to its
configured wait budget and reports incomplete cleanup. An already yielding Roblox
request cannot be forcibly interrupted; RequestTimeout bounds waiting/retries, not
the duration of an engine request. A failed acquisition with an unknown outcome
can leave a lease until the same load is retried or the lease expires.

## Configuration

Persistence options:

| Option | Default | Purpose |
| --- | --- | --- |
| `Stores` | `{}` | Store name to store definition |
| `Adapter` | Roblox DataStore | Explicit storage implementation |
| `RequestTimeout` | `10` seconds | Per-key queue wait / request retry budget |
| `RetryAttempts` | `5` | At most 20 attempts per request |
| `ShutdownTimeout` | `25` seconds | Wait budget for concurrent cleanup |
| `HistoryLimit` | `128` | Bounded diagnostic events |
| `Clock` | Context clock or os.clock | Monotonic scheduling clock |
| `WallClock` | os.time | Shared lease-expiration clock |
| `Wait`, `Spawn`, `Pulse`, `PlayerSource` | Roblox runtime ports | Override for tests/custom runtimes |
| `Random`, `NewToken`, `Logger` | Runtime defaults | Jitter, operation identity and logging ports |

Store definitions:

| Option | Default | Purpose |
| --- | --- | --- |
| `Defaults` | Required | Root object and structural schema source |
| `Schema` | Optional | `(data) -> (boolean, reason?)`, normally a t validator |
| `RenamedFrom` | `{}` | New top-level name to old name |
| `AutosaveInterval` | `60` seconds | Nominal save / lease-renewal interval |
| `SessionTimeout` | `180` seconds | Expiring ownership lease |

SessionTimeout must exceed twice AutosaveInterval plus RequestTimeout. Recurring
saves have jitter; adjust intervals to your request budget and player count.

## Methods and diagnostics

| Method | Result |
| --- | --- |
| `Persistence:GetStore(name)` | Configured store; unknown names raise an error |
| `Store:Load(key, userId?)` | Profile or nil, error |
| `Store:LoadPlayer(player)` | Profile or nil, error |
| `Profile:Get()` | Detached data copy; rejects inactive/expired sessions |
| `Profile:Update(transform)` | boolean, error?; transform returns the next data table |
| `Profile:Save()` | boolean, error? |
| `Profile:Release()` | boolean, error?; repeated confirmed releases succeed |
| `Profile:GetStatus()` | State, Dirty, Revision, SchemaId, SchemaRevision, Expires, Error |
| `Persistence:Step()` | Schedule due saves; automatic with the Roblox pulse |
| `Persistence:GetSnapshot()` | Session statuses and bounded event history, no profile payloads |
| `Persistence:Destroy()` | Release profiles and disconnect observers; raises on incomplete cleanup |

Session states are Active, Closing, Closed and Lost. Failed releases stay Closing
and reject gameplay edits until a later release is confirmed. Lost sessions cannot
write. Inspector includes the Persistence snapshot; the logger reports load/save
failures and retries without intentionally including profile payloads. Keys and
associated UserIds are diagnostic identifiers, so treat diagnostic output accordingly.

## Portable tests

```luau
local memory = Foundry.Persistence.Memory.new()
local persistence = Foundry.Persistence.new({
    Adapter = memory,
    Stores = { Profiles = { Defaults = { Coins = 0 } } },
})
local profile = assert(persistence:GetStore("Profiles"):Load("example"))
assert(profile:Update(function(data)
    data.Coins += 10
    return data
end))
assert(profile:Release())
persistence:Destroy()
```

Memory uses the same copy and synchronous-transform rules and provides
`Read(store, key)` for detached inspection. It is test-only storage, not persistent
Roblox MemoryStore. Supply advancing Clock/WallClock and a yielding or advancing
Wait port to test retries and lease expiration. Portable runtimes call Step and
Destroy explicitly when no runtime ports are supplied.

A custom adapter implements `Update(store, key, transform, userIds?)` and must
atomically commit the returned record, or cancel if the transform returns nil.
Optional CanRequest, IsRetryable, NewToken and adapter-specific size validation
support budget handling and engine integration. There is no cross-key transaction
or automatic purchase-receipt deduplication API in this module.

## Validation coverage

Portable scenarios cover structural upgrades, aliases, incompatible/corrupt data,
concurrent owners, stale writers, retry exhaustion, lost responses, concurrent
edits, save ordering, independent autosaves and failed shutdown recovery. Engine-
port integration executes the actual Foundry Roblox adapter, real t validators,
callback replays, metadata preservation, budgeting, player departure, heartbeat
and automatic shutdown wiring. These are deterministic local checks, not a live
Roblox backend or Studio load test.

Roblox references: [DataStore best practices](https://create.roblox.com/docs/cloud-services/data-stores/best-practices),
[session locking](https://create.roblox.com/docs/cloud-services/data-stores/player-data-purchasing),
and [error codes and limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits).
