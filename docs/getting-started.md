# Getting started

[README](../README.md) · [API reference](api.md) · [Architecture](architecture.md)

## Requirements

Foundry is a shared-realm Luau package for Roblox. Use Wally and Rojo, or import
the bundled model. The server and every client start their own application.

## Wally installation

Add `Foundry = "drme/foundry@=0.1.0"` to your game's `[dependencies]` once that
release is available in the registry, then run `wally install`.
Map the generated Packages directory to `ReplicatedStorage.Packages`:

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Packages": { "$path": "Packages" }
    }
  }
}
```

Require `ReplicatedStorage.Packages.Foundry`. Do not copy just `src/init.luau`:
Foundry needs its sibling source modules and Wally-managed dependencies.

## Source checkout

Run `wally install` in the Foundry repository. In your Rojo project, mount Foundry's
`src` directory as a ModuleScript and its generated Packages directory beside it:

```json
{
  "name": "FoundryExample",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "Foundry": { "$path": "../Foundry/src" },
      "Packages": { "$path": "../Foundry/Packages" }
    }
  }
}
```

These paths are relative to the example project's location; adjust them for your
checkout. Require `ReplicatedStorage.Foundry` in this layout.

For a single model containing Foundry and its dependencies, run
`python3 scripts/check.py` and import `build/Foundry.rbxmx`. Its internal Packages
folder is part of the model. The package source project and the bundled model
project intentionally have different dependency mappings.

## Server bootstrap

```luau
local Foundry = require(game:GetService("ReplicatedStorage").Packages.Foundry)
local app = Foundry:ServerContext({
    Name = "MyGame/Server",
    Platform = game:GetService("RunService"),
    Wait = task.wait,
    Shutdown = { Bind = function(callback) game:BindToClose(callback) end },
    Providers = serverProviders,
})
app:Start()
```

Shutdown is optional. When configured, Foundry registers one callback after startup;
you do not need a second manual BindToClose. You can still call app:Destroy yourself.
The hook does not cover a shutdown that occurs before startup finishes.

## Client bootstrap

```luau
local Foundry = require(game:GetService("ReplicatedStorage").Packages.Foundry)
local app = Foundry:ClientContext({
    Name = "MyGame/Client",
    Platform = game:GetService("RunService"),
    Wait = task.wait,
    Providers = clientProviders,
})
app:Start()
```

Shutdown, Players and Server options are server-only. Choose a suitable lifetime
for a client application and call Destroy when that lifetime ends.

## Validation and cleanup

```luau
local t = Foundry.t
local check = t.strictInterface({ Name = t.string })
local ok, reason = Foundry.Validation.Check(check, { Name = "Example" })

local scope = Foundry.Scope.new()
local trove = scope:CreateTrove()
local part = trove:Add(Instance.new("Part"))
scope:Destroy() -- destroys the owned Trove and its resources
```

No consumer-side t/Trove installation is required. Keep order-sensitive resources
in Scope:Add; Trove is useful for its own instance, signal and promise helpers.
Do not register the same object in both owners.

## Standalone Luau tests

Without the Roblox engine, automatic dependency loading is disabled. Core lifecycle
and scheduler tests remain portable. Inject `Types` or the optional implementation
argument of Scope:CreateTrove when testing code that uses those libraries. The
repository's dependency test runs the real installed t/Trove code with engine ports.
