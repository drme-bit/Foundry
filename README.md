# Foundry

Application lifecycle and runtime infrastructure for Roblox, with explicit dependency
injection, feature boundaries, cleanup, diagnostics, networking and player sessions.

[Getting started](docs/getting-started.md) · [API reference](docs/api.md) ·
[Architecture](docs/architecture.md) · [Contributing](CONTRIBUTING.md)

## Quick start

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Foundry = require(ReplicatedStorage.Packages.Foundry)
local t = Foundry.t

local app = Foundry:ApplicationContext({
    Name = "MyGame/Server",
    Config = { MaxOrders = 12 },
    ConfigSchema = t.strictInterface({ MaxOrders = t.integer }),
    Providers = {
        {
            Name = "Orders",
            Inject = { Rules = "Config" },
            Create = function(deps, scope, runtime)
                return {
                    Cleanup = scope:CreateTrove(),
                    Start = function()
                        runtime.Logger:Info("Orders started", { Limit = deps.Rules.MaxOrders })
                    end,
                }
            end,
        },
    },
})
app:Start()
```

Foundry installs `t`, Trove and SwiftPacket as its own Wally dependencies. Consumers do not need
to install either separately or supply `Types` in Roblox. `Foundry.t` exposes the
type checker; `scope:CreateTrove()` creates a cleaner owned by the scope.

Foundry's scope preserves ordered cleanup and aggregates errors. Resources inside
a Trove follow Trove's own cleanup semantics; use the scope directly when teardown
order matters. The scheduler, network host and player registry remain optional.

## Install

For a published registry release, add the matching version to your game's Wally manifest:

```toml
[dependencies]
Foundry = "drme-bit/foundry@=0.2.0"
```

Run `wally install` and map the generated `Packages` directory into ReplicatedStorage
with Rojo. The dependencies resolve through Wally's package-local aliases.
This checkout targets version 0.2.0; registry publication is a separate step.

For source development or a standalone model:

```sh
wally install
python3 scripts/check.py
```

The check command writes `build/Foundry.rbxmx`, including runtime dependencies and
third-party notices. Use `default.project.json` for the Wally source package and
`model.project.json` for the model with bundled dependencies. See the
[installation guide](docs/getting-started.md) for source mounting and client startup.

## Explicit dependencies

```luau
{
    Name = "Orders",
    Inject = { Sessions = "PlayerRegistry", Server = "ServerInfo" },
    Create = function(deps, scope)
        return Orders.new(deps.Sessions, deps.Server, scope)
    end,
}
```

The context manages beans, their dependency graph and lifecycle. Player lookup
belongs to `PlayerRegistry`, and server metadata belongs to `ServerInfo`.
Player sessions are not individual beans in the application context.

Server and client applications are separate runtimes. Shared feature code is not
automatically replicated state, and a server context does not execute client code.

## Included infrastructure

| Module | Purpose |
| --- | --- |
| Context | Bean registration, dependency order, lifecycle and bounded startup retries |
| Features | Explicit imports, exports and private bindings |
| Scope / Trove | Owned resources and cleanup |
| Runtime | Protected operations and failure-limited callbacks |
| Logger / Inspector | Structured logs, history and detached runtime snapshots |
| Scheduler | Bounded cooperative jobs with scope-owned cancellation |
| Network | Contracts, validation, rate limits and a SwiftPacket adapter |
| PlayerRegistry | Server sessions, characters and per-player modules |
| ServerInfo | Server identity, occupancy, readiness and draining |

## Development

Install the tools pinned in `aftman.toml`, plus the Luau CLI tools (`luau`,
`luau-analyze`, `luau-compile`) on PATH. Then run:

```sh
wally install
python3 scripts/check.py
```

Checks cover portable suites, real dependency integration, module syntax, strict
analysis, documentation links and the bundled model. Engine ports are exercised
with test doubles; these checks do not replace a Roblox Studio playtest.

## License and dependencies

See [LICENCE](LICENCE) for Foundry's existing license and credit terms.
`t`, Trove and SwiftPacket retain their own licenses; see
[third-party notices](THIRD_PARTY_NOTICES.md).


## Automatic networking

Declare the same ordered contracts on both peers:

```luau
Network = {
    Contracts = require(Shared.Network.Contracts),
}
```

Foundry loads its bundled SwiftPacket lazily when creating Network and compiles
contracts into packets. Application code does not create RemoteEvents or a custom
adapter. SwiftPacket owns the underlying reliable/unreliable remotes and batching.
Custom CreateAdapter and explicit Library/PacketsBinding overrides remain supported.

Identical definitions reuse packet objects within one SwiftPacket runtime;
conflicting schemas/policies for the same packet name are rejected. Context
shutdown disconnects its handlers; the underlying SwiftPacket runtime is shared
for the lifetime of the engine environment.

## Persistence

Opt into managed DataStore profiles with automatic structural schema identities,
compatible default reconciliation, session leases, ordered/idempotent retries and
autosave/shutdown cleanup. No developer-maintained version numbers are required.
See [Persistence](docs/persistence.md) for configuration, injected stores, failure
semantics and portable tests.
