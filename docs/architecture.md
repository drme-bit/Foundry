# Architecture

[README](../README.md) · [API reference](api.md)

## Source layout

```text
src/
  init.luau                 supported public exports
  Context/                  composition, container, features, infrastructure
  Lifecycle/                ordered scopes and protected execution
  Diagnostics/              logging and Inspector snapshots
  Tasks/                    cooperative scheduling
  Network/                  contracts, hosts and transport adapters
  Players/                  server session handles and registry
  Server/                   metadata and availability
  Utility/                  validation, signals and bounded journals
  Roblox/Dependencies.luau   engine boundary for Wally dependency loading
```

The context owns beans, dependency ordering and lifecycle. Registry owns sessions;
ServerInfo owns server metadata. Their consumers receive them through Inject.
Core code does not load game configuration, profiles or content assets.

## Dependency ownership

Foundry declares t, Trove and SwiftPacket in wally.toml. SwiftPacket is loaded lazily
only when Network needs the default transport. Contracts alone configure networking. Roblox dependency resolution supports:

1. Wally's aliases beside the installed Foundry module, preserving dependency versions.
2. An internal Packages folder in the bundled model.
3. Foundry and the generated Packages folder mounted beside each other in a source checkout.

Only the Roblox adapter knows about engine globals or instance paths. Missing
installed dependencies fail with an actionable error; they are not silently ignored.
Standalone Luau returns no automatic engine dependencies and uses explicit ports.

Scope preserves deterministic reverse cleanup and aggregates errors. Trove is an
owned child cleaner with upstream semantics; its resources are not promised the
scope's reverse ordering. The scheduler releases finished jobs from indexed owners.

## Lifecycle

Create, Init and Start run in dependency order, with stage barriers. Startup
failures affect their dependent branch while independent beans continue. Recovery
recreates failed/skipped branches after safe cleanup. Runtime operations are never
automatically retried. Consumer beans stop before their dependencies.

Shutdown is an explicit server port. Foundry registers it after startup and clears
the callback's retained application reference on manual destruction. It does not
cover crashes or a close event before startup has finished.

## Players and networking

Sessions are not context beans. The registry subscribes before enumerating existing
players, rejects duplicate/stale lifecycle events and owns per-session modules.
Ready is framework module readiness, not gameplay profile or replication readiness.

Network contracts describe serialization and validate payloads. They do not grant
permissions. Server handlers still enforce ownership, distance and gameplay rules.
Inspector snapshots are not automatically sent to clients.

## Distribution

The source package uses default.project.json and package-local Wally aliases.
model.project.json includes installed dependencies and third-party notices in a
single model. Generated Packages and build outputs are not checked into source.
The release archive excludes tests, scripts, docs and build-only project files.

Use scripts/check.py before release: it verifies source types/syntax, portable
suites, real dependency integration, documentation links, bundled model syntax and
archive boundaries. Roblox Studio playtests are still needed for actual engine behavior.

Persistence owns buffered sessions, lease fencing and per-key ordered requests.
Schema derives serializable structural identities from defaults and reconciles
compatible additions. Value isolates snapshots and enforces synchronous callbacks.
The Memory adapter supports portable checks; Roblox/DataStore contains the engine
UpdateAsync, request-budget, GUID and serialization ports. Infrastructure registers
the manager and named stores as server beans; Inspector reads status snapshots.
See [Persistence](persistence.md) for the public interface and limitations.
