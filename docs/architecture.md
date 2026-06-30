# Architecture Notes

This document records internal contracts that keep typst.nvim maintainable as
project, compiler, preview, diagnostics, completion, conceal, and provider
features grow. Public API details live in `API.md` and
`docs/provider-contracts.md`; this file is about ownership and lifecycle rules.

## Project Resolution

Project resolution produces a project with a root, main file, output plan, and
buffer membership. Resolution order is intentionally conservative:

1. Explicit runtime options and public project API calls.
2. Buffer-local overrides such as Typst main/root variables.
3. Document directives and `.typstmain` hints.
4. Existing dependency graph knowledge for already attached projects.
5. Bounded import scanning.
6. Root heuristics and the current buffer as the final fallback.

The resolver may read bounded source snippets and filesystem metadata, but it
must not start compiler, preview, Tinymist, or watcher work. Attach/lifecycle
code owns side effects after resolution succeeds.

Project identity is keyed by root plus main. Modules should use project API
snapshots for observation and service controllers for mutation instead of
constructing keys by hand.

## Service Ownership

`project.services` centralizes per-project state, but each service has a single
logical owner:

- compiler service: compiler controller, built-in Typst provider, provider
  binding, and watch runner.
- diagnostics service: diagnostics parser/publisher and quickfix/location-list
  integration.
- preview service: preview controller, native preview, and compatibility
  preview integrations.
- operations service: long-running compile/watch/export/render/tool operation
  tracking.
- artifacts service: export/render/compile artifact ownership and cleanup.
- index service: project index, semantic providers, and dirty tracking.

Callers may read service snapshots. They should not add arbitrary fields to a
service table unless they own that service. New persistent fields need a clear
owner, reset path, and test coverage for attach/detach/reset behavior.

Events should be emitted after the corresponding service state is visible to
event handlers. For example, compile-start events must fire after the active
process or watcher handle is stored.

Shared LuaLS shapes for projects, compiler results, watcher state, and service
tables live in `lua/typst/types.lua`. Extend that file when a field becomes a
stable internal boundary; keep local annotations for temporary locals or helper
return shapes that should not be reused across modules.

## Watch Lifecycle

The built-in watcher is a long-running `typst watch` process that emits many
compile cycles. The lifecycle is:

1. Resolve output path and acquire an output lease.
2. Build the watch command and start the process.
3. Store watcher state in the compiler service.
4. Parse stdout/stderr into cycle events.
5. Emit cycle started/succeeded/failed events.
6. Publish diagnostics for failed cycles and clear them after successful cycles.
7. Refresh dependency state and preview consumers after successful cycles.
8. Stop dependency polling, release leases, and drain stop callbacks when the
   watcher exits or is stopped.

Watch process exit is not itself a compile result when at least one cycle was
already parsed. Cycle state is authoritative for diagnostics and preview
refresh.

Successful watch cycles wait briefly for the expected output path to become
readable before refreshing preview. This avoids false failures on slow
filesystems while still failing closed when Typst or a wrapper reports success
without writing the artifact.

Repeated stop/restart/detach requests while a watcher is stopping must append
callbacks and drain them exactly once. They must not overwrite the first
continuation or launch a parallel watcher for the same project.

Raw watch stdout/stderr is retained only in bounded buffers for diagnostics and
status. Debug logs should record stream metrics and parsed status transitions,
not every raw chunk.

## Autocmd Lifecycle

Global runtime setup owns process-exit cleanup, preview follow-buffer hooks, and
shared user commands. Buffer attach owns buffer-local autocmds, mappings, folds,
conceal, omnifunc, and dirty/index refresh hooks.

The Typst ftplugin intentionally attempts attach immediately and again on the
next scheduled tick. The project lifecycle attach path must therefore be
idempotent: no duplicate project attach events, buffer autocmd groups, mappings,
Tinymist startup requests, or feature reapplication unless the underlying
configuration/signature changed.

Detach must emit buffer-detach events before project-prune events. Prune events
represent project registry removal, not merely one buffer leaving a project.

User autocmd callbacks run outside service mutation internals where possible.
When a state mutation is requested from inside a typst.nvim user event, defer it
through the event module so handlers observe a stable payload.

## Cache Invalidation

Cache owners should register with the cache registry when they expose reset,
clear, or reload behavior. Cache clearing is a recovery path; failures should be
logged and isolated so one bad cache cannot abort a full reset.

Common invalidators:

- config generation: setup/reset/profile changes.
- metadata generation: Typst metadata refresh and custom conceal changes.
- buffer changedtick: source edits.
- Tree-sitter parser callbacks: changed syntax ranges for conceal/query caches.
- project index dirty marks: file writes, attach/detach, imports, bibliography,
  and provider registration changes.
- path completion TTL plus directory signature: filesystem completions.
- operation completion/cancellation: output leases and artifact ownership.

Cursor movement and window-local reveal state should not invalidate collected
syntax matches. Conceal match collection and reveal filtering have separate
cache keys so redraw hot paths avoid full Tree-sitter collection work.

## Provider Contracts

Provider contracts are normalized by `typst.integrations.provider_adapter` and
documented in `docs/provider-contracts.md`.

Providers may finish synchronously, call a callback, return a pending handle, or
return a raw handle while completing through a callback. Call sites decide
whether a table is expected to be a terminal result or an active handle. In
handle mode, result-shaped terminal tables must be explicit with fields such as
`ok`, `code`, `reason`, or `stopped`.

The shared pending helper provides common `finish`, `on_finish`, and `cancel`
behavior for adapter-owned pending handles, preview export continuations, and
native preview continuations. It does not decide result-vs-handle
classification; the owning adapter does. Internal pending observation is
method-style (`handle:on_finish(callback)`). Dot-style observation is a
call-site compatibility choice, not something inferred from callback arity.

Provider callbacks must be single-shot from typst.nvim's perspective. Duplicate
callbacks after timeout or cancellation are logged and ignored. Cancellation
results are terminal unless the provider returns `{ pending = true }` to signal
that shutdown is still in progress.

Custom providers should keep side effects inside their documented provider
surface. Compiler providers own compile/watch/stop/output behavior. Semantic
providers do not own diagnostics unless they explicitly declare diagnostic
ownership. Preview and viewer providers own display/open behavior, not compiler
artifact state, unless they invoke export/compile APIs that acquire artifact
ownership explicitly.

## Migration Plan

The current architecture is intentionally migration-friendly rather than a
rewrite target. Refactors should land behind compatibility facades and preserve
the existing public API.

### Typed Service Controllers

Service modules under `typst.project.services.*` are the controller boundary.
New mutations should be added as named controller methods instead of open-ended
field writes when the transition has invariants, side effects, or event order.
Generic `set(project, fields)` remains as a compatibility path for simple field
updates, tests, and migration glue.

Add controller methods in this order:

1. compiler start/finish/stop transition methods;
2. preview activate/refresh/stop transition methods;
3. diagnostics publish/clear/list ownership methods;
4. index dirty/collect/freshness methods.

Each method should document the fields it owns and should return the updated
service table or a structured refusal result.

### Project Lifecycle Split

`project/lifecycle.lua` is now the compatibility coordinator for attach,
detach, reload, and main-file transitions. Responsibility-specific helpers live
under `project/lifecycle/`:

- `buffers.lua`: buffer autocmd installation, TOC follow hooks, omnifunc, dirty
  changedtick suppression, and reapplying attached buffers after config reload.
- `events.lua`: attach/detach/prune event payloads and previous-project stop
  handoff.

Future splits should continue this pattern without changing commands or public
project APIs. Good next boundaries are feature application
(mappings/folds/conceal/indent/signatures) and integration startup
(Tinymist/provider hooks). The scheduled ftplugin attach contract stays in the
coordinator and must keep the idempotence tests passing.

### Compiler Event Pipeline

Compiler user-event emission now flows through `typst.compiler.events`. Built-in
compile/watch paths and provider-neutral state transitions emit normalized
event kinds such as `compile_start`, `cycle_success`, and `compile_stopped`.
That module maps them onto the existing public `TypstCompile*` User events and
filters payload fields so raw process output does not accidentally become part
of the public contract.

The remaining long-term step is to move side effects behind a reducer. Watch
parser/state should eventually produce normalized compiler events before
diagnostics, artifacts, dependency refresh, and preview consumers run:

```lua
{ kind = "cycle_start", generation = n, cycle = c }
{ kind = "cycle_success", generation = n, cycle = c, output = path }
{ kind = "cycle_failure", generation = n, cycle = c, diagnostics = by_buffer }
{ kind = "watch_exit", generation = n, result = result }
```

A compiler event reducer should own service transitions and event emission.
Diagnostics, dependency refresh, artifacts, and preview refresh should consume
those normalized events instead of being embedded directly in parser handlers.

### Jobs Namespace

Async primitives should move behind a `typst.jobs` namespace over time:

- `jobs.pending`: shared pending handle helper.
- `jobs.operation`: tracked operations.
- `jobs.process`: process spawning and shutdown.
- `jobs.provider_adapter`: provider invocation normalization.

Compatibility modules such as `typst.core.operation` and
`typst.integrations.provider_adapter` should remain until the next major API
boundary. The `typst.jobs.*` facades already exist for new internal code that
wants the migration namespace without changing behavior.

### Native Preview Split

`preview/native.lua` remains the public native preview facade, while
transport-specific work lives in smaller modules:

- `preview/native/viewer.lua`: viewer target open/result handling.
- `preview/native/browser.lua`: browser target open/refresh/follow handling.
- `preview/native/pending.lua`: shared pending export continuation handling.
- `preview/native/state.lua`: preview service transition helpers and
  follow-project cleanup.

Server route and file-shell ownership still sit behind the browser transport and
can be split later if that file grows again. The facade must keep native browser
pending refresh/restart tests passing.

### Cache Registry Stats

The cache registry exposes both detailed `status()` entries and aggregate
`stats()` counters. New cache owners should provide reset/clear/reload methods
where appropriate and should register enough metadata for health/report output
to show loaded, unloaded, reset-capable, clear-capable, and reload-capable
counts.
