# typst.nvim Lua API

The stable Lua entrypoint is:

```lua
local typst = require("typst")
typst.setup({})
```

The public API version is available through:

```lua
typst.api_version()
typst.version()
```

## Stable Namespaces

Prefer structured namespaces for new code:

```lua
typst.project.get()
typst.project.snapshot()
typst.project.projects()
typst.project.set_main()
typst.compiler.compile()
typst.compiler.watch()
typst.compiler.stop()
typst.viewer.view()
typst.artifact.export()
typst.render.fragment()
typst.evaluation.eval()
typst.template.init()
typst.development.test()
typst.semantic.references()
typst.edit.unwrap_function()
typst.completion.complete()
typst.package.info()
typst.metadata.symbol()
typst.symbol.info()
typst.bibliography.diagnostics()
typst.providers.register()
typst.invalidation.subscribe(project, "buffer_changed", callback)
```

## Stability Policy

The stable API level is additive within a level. Stable function, command,
event, provider-kind, or documented result-field changes need a migration note;
removals need a compatibility alias for one minor release or an API-level bump.
Experimental symbols are explicitly reported by `typst.experimental_symbols()`
until they are promoted or removed with a migration note.

CI runs `tests/run_api_stability.sh` as the public API stability gate. Provider
contract changes must also pass `tests/run_provider_matrix.sh` across Linux,
macOS, and Windows.

Process-backed background workflows return cancellable result tables:

```lua
local result = typst.compiler.compile({}, function(done)
  print(done.ok, done.code)
end)

if result.pending then
  result.cancel()
end
```

## Namespace-Only Lua API

The root module does not export workflow, edit, package, symbol, completion, or
provider helper functions. Use the stable namespaced API instead.

## Project State

`typst.project.get()` returns the live project object for integrations that
need direct project access. New integrations should prefer copied project
contexts:

```lua
local project = typst.project.snapshot()
local projects = typst.project.projects()
```

Snapshots are plain Lua tables containing project identity, root/main/output
paths, status, files, dependencies, artifacts, and invalidation generations.
Mutating a snapshot never mutates typst.nvim's live project registry.

Registered external providers receive these copied project contexts by default.
This includes compiler, viewer, export, render, eval, development, semantic,
format, lint, grammar, index, and TOC providers. Built-in providers and
typst.nvim internals keep using the mutable project object they own.

## Invalidation

Projects expose a central invalidation bus. The current built-in events are:

- `buffer_changed`
- `disk_file_changed`
- `dependencies_changed`
- `provider_changed`
- `manual`
- `index_changed`

Subscribe with:

```lua
local unsubscribe = typst.invalidation.subscribe(project, "*", function(event)
  print(event.event, event.generation)
end)

unsubscribe()
```

The bus replaces ad hoc polling of unrelated generation counters for extension
code. Existing internal counters still exist as implementation details.
