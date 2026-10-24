# Contributing to Foundry

## Development setup

Install Aftman and the tools pinned in aftman.toml. Install the Luau CLI tools
luau, luau-analyze and luau-compile on PATH. Then run:

```sh
wally install
python3 scripts/check.py
```

Do not edit generated Packages. Change wally.toml and reinstall dependencies instead.
The lockfile records the exact dependency graph used for development checks.

## Design rules

- Keep game-specific services, profiles, content and authorization outside Foundry.
- Declare bean dependencies through Inject or Dependencies.
- Scope-own subordinate resources; do not double-own returned beans or player modules.
- Preserve teardown order, failure isolation and bounded diagnostics.
- Keep engine-specific behavior behind explicit ports or the Roblox adapter.
- Keep wire compatibility changes explicit; version contracts when semantics change.
- Add behavioral tests for changed lifecycle, transport or ownership semantics.

## Documentation

All maintained documentation is in English. README is the entry point;
docs/getting-started.md covers installation, docs/api.md is the reference, and
docs/architecture.md describes ownership and implementation seams.

Update signatures, defaults, return values, errors and examples together with code.
Use runnable examples or identify required application bindings. Avoid local paths,
game-specific assumptions and instructions for unreleased features. Keep links relative.

## Release preparation

Run the checks, inspect the Wally package file list, choose the intended version,
and review the existing LICENCE and third-party notices. Publishing or pushing
changes is a separate maintainer action; the check script does neither.
