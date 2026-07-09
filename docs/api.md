# typst.nvim Lua API

`API.md` is the normative compatibility contract. This file explains how to use
that public surface and mirrors the same stable/experimental tiering for
readability.

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

Machine-readable workflow availability is available through:

```lua
local caps = typst.capabilities()
print(caps.compiler.provider)
print(caps.preview.native_browser)
```

`capabilities()` returns best-effort sections for Typst, Tree-sitter, Tinymist,
compiler, preview, and diagnostics. Inspection failures are reported in the
section, for example `caps.compiler.ok = false` with a stable `reason`, instead
of throwing for expected provider/configuration problems.

## API Tiers

Prefer structured namespaces for new code, but do not treat an installed
namespace as stable by itself. Stable symbols are the exact dotted names
returned by `typst.stable_symbols()`. Installed helpers outside that list are
reported by `typst.experimental_symbols()` before 1.0.
Set `api.experimental_warnings = true` in setup to log and notify once per
experimental Lua symbol when it is called.

Mixed namespaces currently contain the stable workflow entry points:

```lua
typst.project.get()
typst.project.snapshot()
typst.project.projects()
typst.project.set_main()
typst.compiler.compile()
typst.compiler.watch()
typst.compiler.stop()
typst.viewer.view()
```

Experimental namespaces and helpers remain useful for plugin users and
integrations, but their signatures can change before promotion:

```lua
typst.artifact.export()
typst.render.fragment()
typst.template.init()
typst.semantic.references()
typst.edit.unwrap_function()
typst.completion.complete()
typst.package.info()
typst.metadata.symbol()
typst.symbol.info()
typst.bibliography.diagnostics()
typst.providers.register()
typst.report({ open = true })
typst.ui.bug_report({ open = true })
typst.invalidation.subscribe(project, "buffer_changed", callback)
```

## Stability Policy

The stable API level is additive within a level. Stable function, command,
event, provider-kind, or documented result-field changes need a migration note;
removals need a compatibility alias for one minor release or an API-level bump.
Experimental symbols are explicitly reported by `typst.experimental_symbols()`
until they are promoted or removed with a migration note. Internal modules
under `typst.core.*`, `typst.resources.*`, `typst.project.store`,
`typst.project.registry`, `typst.project.services.*`, `typst.runtime.*`, and
`typst.internal.*` are not API even when loadable.

Earlier reset-phase docs treated several whole namespaces as stable. Before
1.0, that promise has been narrowed to exact dotted symbols without bumping the
API level: the namespaces still load, but artifact, completion, editing,
metadata, provider, preview-helper, and reset helpers are
experimental unless `typst.stable_symbols()` lists the exact name.

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

Project-scoped public Lua wrappers use a shared no-project policy. Passive
inspection APIs such as `compiler.status()`, `compiler.current_output()`,
`viewer.preview_status()`, `project.services()`, and report helpers reuse an
attached project, an explicit `project`, or an explicit key (`key` or
`project_key`, with `key_encoded = true` for command-safe encoded keys); they
do not create scratch projects from dashboards, timers, statuslines, or other
non-Typst buffers, and they do not notify by default when no project exists.
Cleanup APIs such as `viewer.clean()` and `viewer.clean_preview()` also use
no-create resolution, but remain action APIs. When no project is available,
wrappers return `nil, { reason = "no_project", ... }` or a result table with
`ok = false` and `reason = "no_project"`. If an explicit key cannot be
resolved, wrappers return `unknown_project_key` or `ambiguous_project_key`
instead of `no_project`.

Action APIs such as compile, watch, preview, render, export, navigation,
and semantic calls may resolve or create project state only for Typst source
buffers. Calls from a non-Typst buffer fail closed with the same `no_project`
reason instead of compiling an unintended main. Integrations should pass
`{ bufnr = typst_bufnr }`, `{ project = project }`, or an explicit project key
when the current buffer is not the Typst source. `viewer.capabilities()` is
project-free; preview capabilities are project-scoped. Viewer and preview
inverse-search wrappers also try `opts.path`/`opts.source_path` against loaded
buffers and existing project graphs. When an explicit source path is supplied
but is not associated with any loaded buffer or existing project graph, they
return `source_path_not_in_project` instead of falling back to the focused
project.

When an action API with a callback is blocked by deferred project resolution,
the callback receives `{ ok = false, reason = "resolution_pending", ... }` and
the wrapper returns that same payload. Without a callback, stable `nil_error`
endpoints keep the normal `nil, err` resolution-failure convention.

External compiler provider compile/watch/stop timeouts retain typst.nvim's
output lease because timeout is not proof of process exit. Use
`typst.compiler.force_clear({ key = project_key })` to discard that retained
state for attached or bufferless projects; its result sets `stopped = false`
because the provider process was not confirmed stopped.

Setup events have a fixed order. First setup emits `TypstEventInitPre` and then
`TypstEventInitPost`. Reconfiguration emits `TypstEventInitPre`,
`TypstEventConfigChanged`, and then `TypstEventInitPost`; the config-changed
event fires after configuration is installed and attached buffers are reapplied.
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
provider helper functions. Use the public namespaced API instead, and check
`stable_symbols()` before relying on compatibility.

## Project State

Stable project methods that return project state return copied public project
snapshots. This includes `typst.project.get()`, `snapshot()`, `projects()`,
`attach()`, `detach()`, `set_main()`, `reload_state()`, and
`toggle_main().state`:

```lua
local project = typst.project.get()
local projects = typst.project.projects()
```

Snapshots are plain Lua tables containing project identity, root/main/output
paths, status, files, dependencies, artifacts, and invalidation generations.
Mutating a snapshot never mutates typst.nvim's live project registry.

### Migration: public project methods now return snapshots

Before this hardening release, some public project methods returned live project
tables. They now return copied public snapshots. Code that only reads identity,
root, main, output, status, files, dependencies, diagnostics, and artifacts
should continue to work. Code that mutates services, buffers, resolutions, or
compiler state must move behind a provider, a public command/API call, or an
internal typst.nvim module. User configs and external integrations should not
require `typst.project.store` or `typst.project.registry`; tests and internal
runtime modules may use those live-state modules deliberately.

Snapshots can be passed back into project-scoped public APIs while the backing
project instance is still live. Snapshot resolution checks both the project key
and a session-local instance token. If the project has been pruned, or if the
same root/main key has been recreated as a new project instance, that explicit
snapshot fails with `unknown_project_key` rather than operating on copied or
unrelated state.

Registered external providers receive these copied project contexts by default.
This includes compiler, viewer, export, render, semantic,
format, lint, index, and TOC providers. Built-in providers and
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
