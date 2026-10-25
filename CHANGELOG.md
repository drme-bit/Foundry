# Changelog

## 0.2.0 — in development

- Add server Persistence and injectable named stores without manual data versions.
- Derive schema identities from defaults, reconcile compatible additions and support explicit top-level aliases.
- Fence session owners, retain uncertain writes, budget and retry ordered DataStore requests, autosave and release on player exit/shutdown.
- Add Memory storage, Persistence Inspector snapshots and deterministic storage/engine-port fault tests.

- Add ApplicationContext with automatic runtime detection, waiting and server shutdown defaults.

- Bundle SwiftPacket 0.1.4 and lazily autoconfigure the Network transport from contracts.
- Reuse compatible packet definitions and reject conflicting schemas/policies.
- Preserve custom adapters and explicitly selected precompiled packet bindings.
- Test real SwiftPacket packet/schema serialization through engine transport ports.

## 0.1.0 — initial release

- Independent public package manifest under drme/foundry.
- Explicit server/client contexts, injection and private feature bindings.
- Ordered resource ownership, startup recovery and protected runtime callbacks.
- Scheduler, network contracts, diagnostics and server/player infrastructure.
- Optional Shutdown.Bind port with safe repeated/manual destruction.
- Packaged t and Trove dependencies, automatic Roblox resolution and owned Trove scopes.
- English installation guide, API reference, architecture and contribution docs.
- Portable and real-dependency integration checks, bundled model and archive validation.
