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

Common result fields:

```lua
---@class TypstResult
---@field ok boolean? True when the operation succeeded.
---@field pending boolean? True while async work is still active.
---@field stopped boolean? True only when stop was confirmed.
---@field idle boolean? True when there was no active work to stop.
---@field reason string? Machine-readable failure or cancellation reason.
---@field message string? Human-readable detail.
---@field orphaned boolean? True when shutdown could not be confirmed.
---@field orphan_retained boolean? True when typst.nvim retained an orphan.
---@field stale boolean? True when a late generation result was ignored.
```

Cancellation callbacks settle when a stop is confirmed or when an operation is
retained as an orphan. `on_finish()` callbacks are stricter: they run only when
the underlying process/provider really exits. Retained orphans stay visible for
diagnostics and keep owned resources guarded until that later real exit or an
explicit cleanup/reset path.

External compiler provider compile/watch/stop timeouts retain typst.nvim's
output lease because timeout is not proof of process exit. Use
`typst.compiler.force_clear({ key = project_key })` to discard that retained
state for attached or bufferless projects; its result sets `stopped = false`
because the provider process was not confirmed stopped.
The Lua symbol is experimental for now; the supported user-facing recovery path
is `:TypstCompilerForceClear[!] [project-key]`.

Lua callers may pass raw `project.key`, encoded `key_display` with
`key_encoded = true`, or a direct `project` object. The command should use the
encoded `key_display` printed by `:TypstStatusAll!`. When Lua code already has a
project object, pass `project = project`; it is authoritative even if `key` is
also present. Without `key_encoded = true`, an ambiguous raw/encoded collision
returns `ambiguous_project_key` instead of guessing.

```lua
---@class TypstCompilerForceClearResult
---@field ok boolean
---@field stopped false False when state was discarded without proof of shutdown.
---@field forced boolean? True only when the caller passed bang/force to bypass the stopping_failed guard.
---@field discarded boolean? True when typst.nvim state was discarded.
---@field released_lease boolean? True when typst.nvim released its lease.
---@field reason '"force_cleared"'|'"not_external_provider"'|'"nothing_to_clear"'|'"not_stopping_failed"'|'"no_project"'|'"unknown_project_key"'|'"ambiguous_project_key"'
---@field key string? Project key accepted by the public API.
---@field key_display string? Command-safe encoded project key.
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
