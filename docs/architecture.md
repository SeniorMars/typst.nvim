# Architecture Notes

This document records internal contracts that keep typst.nvim maintainable as
project, compiler, preview, diagnostics, completion, conceal, and provider
features grow. Public API details live in `API.md` and
`docs/provider-contracts.md`; this file is about ownership and lifecycle rules.

Detailed maintainer inventories live next to this overview:

- `docs/services.md` records project service owners and reset rules.
- `docs/state.md` records process, project, buffer, and window state owners.
- `docs/diagnostics.md` records external diagnostic path policy and tests.
- `docs/event-ordering.md` records public event ordering and provider identity.
- `docs/cache-invalidation.md` records cache owners, invalidators, and budgets.
- `docs/autocmd-lifecycle.md` records buffer-local and runtime autocmd rules.
- `docs/stable-core-decisions.md` records release policy decisions that should
  not be hidden in code comments.

## Stability-First Target Layout

The long-term layout should make typst.nvim read like a Typst workflow
environment, not a bag of feature files. The important questions are:

1. Who owns project identity?
2. Who owns live resources?
3. Who owns generated outputs?
4. Who owns compiler/watch lifecycle?
5. Who publishes diagnostics?
6. Which modules are public API versus internal implementation?

### Subtractive Architecture Rule

New architecture is allowed only when it collapses duplicate ownership,
standardizes an existing contract, or removes repeated boilerplate. A refactor
that adds a framework without deleting or simplifying an older reset path,
operation path, async result shape, or API wrapper path should not merge during
stable-core hardening.

The approved stabilization architecture budget is intentionally small:

1. One reset manifest and one reset/prune/exit orchestrator.
2. One preview controller boundary with small backend adapters.
3. One declarative runtime API policy table.
4. One pending/cancel contract used by providers, preview, and operations.
5. One output lease owner.

Anything larger needs a specific deletion plan and tests showing that an older
owner or contract disappeared.

### Current Target

The stable-core target is:

```text
lua/typst/
  api/             Public Lua facade, stable symbol spec, runtime policy table.
  runtime/         Setup, reset manifest, resource manager, commands, health.
  project/         Root/main resolution, registry, lifecycle, services, index.
  resources/       Output leases, liveness snapshots, cleanup drivers.
  compiler/        Compile/watch lifecycle and provider binding.
  preview/         Preview controller, pending helpers, small backend adapters.
  viewer/          Artifact opening and source-sync commands.
  diagnostics/     Diagnostic parser, policy, publisher, quickfix/location list.
  completion/      Completion sources, cache, and frontend adapters.
  conceal/         Conceal matching, rendering, custom rules, inspection.
  edit/            Folds, indent, motions, text objects, transforms.
  workflows/       Export, render, template, clean, lint, format.
  integrations/    Tinymist, provider adapter, and shallow external adapters.
  ui/              Commands, reports, status lines, notifications.
  core/            Dependency-light primitives only.
```

This target is not a mandate for file moves. Move ownership first and files
second. A file move is acceptable only after tests pin the boundary it
represents.

### Not Allowed During Stable-Core Hardening

Do not add these until they replace existing complexity instead of sitting on
top of it:

- a generic task framework;
- a UI element/layout framework;
- a provider spec DSL or provider marketplace;
- a broad picker backend framework;
- generated documentation for every internal module;
- a new event bus;
- a highly generic diagnostic-tool engine.

Small helpers are allowed when they remove duplication. For example, a
diagnostic tool result helper or provider result normalizer is acceptable; a
cross-plugin task engine is not.

## Top-Level Mental Model

When a maintainer opens `lua/typst/`, the directories should communicate the
product workflow and ownership model:

```text
api          public Lua surface
runtime      setup/reset/autocmd/commands/health
config       configuration
core         reusable primitives
project      root/main/project identity
resources    liveness snapshots, output leases, cleanup drivers
compiler     compile/watch
diagnostics  diagnostic parsing/publishing
viewer       open generated output
preview      live preview sessions
navigation   toc/gf/items/labels/citations
editor       motions/textobjects/format/folds/indent
completion   completion sources/frontends
conceal      visual conceal engine
bibliography bibliography-specific support
metadata     generated Typst metadata
workflows    export/render/lint/format/etc.
integrations external plugin/tool adapters
ui           command/report/status presentation
internal     debug/compat/invariant checks
```

The ownership model behind that layout is:

```text
project owns identity
runtime.resource_manager owns reset/prune/exit ordering
resources expose liveness snapshots and output leases
compiler owns compile/watch state
preview owns preview sessions
viewer owns output opening
diagnostics owns diagnostic publication
navigation/editor/completion/conceal own editing experience
ui owns presentation
integrations adapt external tools
core owns primitives only
```

## What Not To Do

Do not create a generic `features/` directory:

```text
features/compiler.lua
features/preview.lua
features/diagnostics.lua
features/navigation.lua
```

That hides ownership and makes cleanup rules harder to audit.

Do not put every external-facing behavior under `integrations/`:

```text
integrations/compiler.lua
integrations/preview.lua
integrations/viewer.lua
```

Compiler and viewer are the core workflow providers for the first stable-core
pass. Preview remains available, but native browser/source-sync/provider
preview behavior is an advanced subsystem until its lifecycle contract is as
boring as compile/view.

Move ownership only when tests pin the boundary. The layout should follow
boundaries with regression coverage:

```text
project resolver does not mutate registry
project.store owns live project identity
project.attachments owns buffer hook installation
resources.session decides project activity
resources.outputs owns leases
runtime.resource_manager is the reset/prune/exit cleanup entry point
diagnostics publisher is the only diagnostic writer
compiler.fanout routes compiler-state post-result consumers
typst.compiler decides stop/timeout semantics
typst.preview.controller decides native/callback preview stop semantics
typst.viewer.api decides viewer/source-sync command semantics
```

## Hard Ownership Boundaries

Core modules should be boring and dependency-light. `core/` must not know about
Typst projects, preview, compiler, diagnostics, or UI. It owns reusable
primitives such as process shutdown, pending handles, path helpers, generic
result predicates, logging, events, and caches. Compiler-specific result
normalization belongs in `compiler.state_machine`; `core.result` should retain
only generic result predicates and constructors.

Project modules own identity, not live resources. They answer root, main, key,
buffer membership, dependency graph, index state, and service-table existence.
They should not know how to kill a compiler, stop a preview server, release an
output lease, or publish diagnostics.

Runtime resource management is the liveness migration boundary. Runtime reset,
exit cleanup, and stop-before-prune orchestration go through
`runtime.resource_manager` and its reset manifest. `resources.session` exposes
the project/global liveness view, `resources.outputs` owns generated-output
leases and locks, and deleted `resources.supervisor` should not be restored.
Callers should use `runtime.resource_manager` directly rather than learning
backend-specific compiler, preview, operation, diagnostics, or output details.
Temporary reset overlaps must be listed in
`runtime.resource_manifest.migration_duplicate_policy()` with the older owner,
reason, and removal plan. That policy should normally be empty; new reset
owners should replace older cleanup paths instead of running beside them.

Compiler modules own compile/watch state, provider policy, Typst CLI behavior,
watch output parsing, and compiler events. `typst.compiler` decides when a
timeout is an unconfirmed writer and when leases may be released. Do not extract
a full compiler controller before the stable-core boundary is pinned; keep the
current module as the compatibility and lifecycle entry point while tests harden
the behavior. Post-result side effects such as artifact ownership, diagnostics,
dependency refresh, logging, and events route through `compiler.fanout` today.
Viewer and preview refresh route through `compiler.consumers` from the existing
API paths rather than being duplicated by each backend.

Diagnostics modules own diagnostic publication. Only `diagnostics.publisher`
should call `vim.diagnostic.set` for compiler/lint diagnostics. Parser,
policy, quickfix, and count helpers should feed that publisher or clearly
document an exception.

Viewer and preview are separate workflows. `typst.viewer.api` owns viewer
commands and preview-facing public command orchestration. A viewer opens or
controls existing artifacts. `typst.preview.controller` owns custom and native
preview lifecycle decisions.
`preview/native/*` owns native browser preview details. Do not extract full
viewer controllers before the stable-core boundary is pinned. Source-sync
capability reporting should make this distinction explicit.

Navigation modules return item lists and jump actions. UI modules decide how to
show them, and integrations supply optional semantic data. Navigation should not
depend directly on Telescope, fzf-lua, Snacks, or other picker implementations.

Editor modules own editing behavior: motions, text objects, transforms, folds,
indent, insert mappings, match highlighting, and formatexpr. Project lifecycle
may apply or detach editor hooks, but it should not know their internal behavior.

Workflows own user-triggered jobs that are not the main compiler loop: export,
render, template init, clean, lint, and format.
Output-producing workflows should use `resources.outputs`,
`resources.operations`, `core.process`, and the provider adapter instead of
talking directly to low-level lease tables.

Integrations adapt external tools and plugins. They should not own core
typst.nvim resource lifecycle. Tinymist, coc, picker adapters, Tree-sitter
adapter glue, and provider invocation normalization belong here; preview and
compiler controllers do not.

UI owns presentation only: commands, reports, status lines, notifications,
selection, and log display. UI modules may ask project/resources/compiler/preview
for snapshots, but they should not mutate service state except by calling public
or controller APIs.

## Project Resolution

Project resolution produces a project with a root, main file, output plan, and
buffer membership. The compatibility facade is `typst.project`; the stateful
pieces are split underneath it:

- `project/resolver.lua` orchestrates source-specific resolvers and must not
  mutate registry state. Root detection, explicit main sources, graph matching,
  and import-scan fallback live under `project/resolver/`.
- `project/registry.lua` owns live project and buffer-to-project maps.
- `project/init.lua` remains the public/internal facade that commits resolver
  candidates into the registry and preserves existing API entry points.

Resolution order is intentionally conservative:

1. Explicit runtime options and public project API calls.
2. Buffer-local overrides such as Typst main/root variables.
3. Document directives and `.typstmain` hints.
4. Existing dependency graph knowledge for already attached projects.
5. Bounded import scanning.
6. Root heuristics and the current buffer as the final fallback.

Configured `main = { [root] = main }` table keys are normalized during
`setup()`. Absolute keys are preferred. Relative keys resolve against
`main_base_dir` when it is set; otherwise they keep the compatibility behavior
of resolving against the setup-time cwd and emitting a warning. Resolver code
must not reinterpret those keys against the live cwd, because `:cd`/`:lcd` must
not change project identity. Resolver candidates carry `main_confidence`:
explicit sources are high confidence, import-scan/existing graph matches are
medium confidence, and fallback guesses such as current-buffer or nested
`main.typ` are low confidence. User-facing compile/watch paths warn once per
project before using the nested `main.typ` heuristic.

The resolver may read bounded source snippets and filesystem metadata, but it
must not start compiler, preview, Tinymist, or watcher work. Attach/lifecycle
code owns side effects after resolution succeeds. Attach defers import scanning
and marks the attached project with `resolution_pending = "import_scan"` while a
scheduled incremental scan runs. Deferred scans do not reassign buffers in the
background; they record a suggested main, and command-time project lookup may
accept that completed suggestion before compiler, preview, or navigation work
starts. Explicit synchronous resolver calls still use the bounded scanner. Both
paths are capped by candidate count, ancestor depth, and filesystem entry count.
Import scan uses a short-lived path/root/config/root-metadata cache, and roots
that exceed the entry cap abort the import-scan attempt instead of using partial
scan results.

Project identity is keyed by root plus main. Modules should use project API
snapshots for observation and service controllers for mutation instead of
constructing keys by hand.

## Result and Resource Boundaries

`core/result.lua` defines shared result constructors and predicates for
compiler, provider, preview, and operation lifecycle code. In particular,
`is_confirmed_stopped()` is the only generic predicate that should release owned
resources, while timeout/orphaned/pending stop results remain unconfirmed.
`core.result.reason` and `core.result.status` are the shared vocabulary for
common lifecycle outcomes; subsystem result helpers may add fields, but should
reuse those reason/status strings instead of inventing near-duplicates.

Project-scoped resource state is observed through `resources/session.lua`. It
summarizes compiler handles, preview activity, active/retained operations,
diagnostic buffers, and active output leases for a project. Cleanup code may
still delegate to compiler/preview/operation controllers, but pruning and
reporting should use the session view when asking whether a project still owns
live resources.

Generated output ownership goes through `resources/outputs.lua`. It wraps the
low-level in-process lease table, adds atomic file-backed lock directories under
the typst.nvim cache directory for cross-Neovim collision detection between
sessions that share the same cache root, and provides project-filtered ownership
views. Lock owner records include PID, output path, and project owner metadata.
Dead-owner locks are recovered; live-PID locks are not auto-stolen by age alone
because a long-running watch may legitimately hold the output. Missing, empty,
unreadable, or corrupt owner records are treated as active for a short
incomplete-lock grace period so partially-written acquisitions are not stolen,
then recovered. Compiler, watch, render, export, reports, and health should
depend on `resources.outputs` rather than `core.path_leases` directly.

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

Compiler lifecycle fields should move through named transition helpers in
`typst.project.services.compiler`: compile start/finish, watch start/cycle/exit,
confirmed stop, unconfirmed stop, and force-clear. The generic `set()` helper
remains for compatibility and tests, but new compiler lifecycle code should use
the transition helpers so generation, active handle, output lease, and status
semantics stay together.

Events should be emitted after the corresponding service state is visible to
event handlers. For example, compile-start events must fire after the active
process or watcher handle is stored.

Shared Lua annotations live in `lua/typst/types.lua`, but this stabilization
patch should avoid a broad type-shape overhaul. Add reusable shapes only when a
field becomes a stable internal boundary; keep local annotations for temporary
locals or helper return shapes that should not be reused across modules.

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

Cache and local-state owners should register with the cache registry when they
expose reset, clear, reload, buffer-forget, buffer-detach, or window-forget
behavior. Cache clearing is a recovery path; failures should be logged and
isolated so one bad cache cannot abort a full reset or buffer teardown.

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

Providers may finish synchronously, call a callback, return an explicit pending
handle, or return a userdata handle while completing through a callback. Async
table handles must include `pending = true`; result-shaped terminal tables must
be explicit with fields such as `ok`, `code`, `reason`, or `stopped`.

Call sites that install lifecycle state, retain output leases, or release output
leases must use `provider_adapter.classify_return()`,
`provider_adapter.is_active_handle()`, or
`provider_adapter.is_terminal_result()` instead of raw `type(result) == "table"`
and `pending` checks. Structural result fields such as `path`, `output`, or
`artifacts` are valid terminal results only after the caller has declared them
to the adapter; cancelable structural tables are invalid async handles unless
they opt in with `pending = true` or an internal call site supplies an explicit
handle predicate.

The shared pending/operation lifecycle contract provides common `finish`,
`on_finish`, `on_result(result, handle)`, and `cancel` behavior for
adapter-owned pending handles, process-backed operations, preview export
continuations, and native preview continuations. It does not decide
result-vs-handle classification; the owning adapter does. Internal observation
is method-style (`handle:on_finish(callback)` or `handle:on_result(callback)`).
Dot-style observation is a call-site compatibility choice, not something
inferred from callback arity.

Provider adapter convergence is intentionally incremental. The adapter uses the
small `typst.integrations.provider_lifecycle` bridge for timeout, cancellation,
duplicate-result suppression, and public pending-handle shape. Do not move the
adapter wholesale onto `core.operation` until that change deletes an older
provider lifecycle path in the same patch. Until then, `core.operation` owns
process-backed operations and `provider_lifecycle` owns provider-returned
pending handles.

Watch migration follows the same rule. `typst watch` process stop/settle
semantics use the shared operation contract, but watch cycle parsing, stream
queues, dependency polling, partial-line flushing, and per-cycle diagnostics are
compiler-domain state. Do not move watch cycles into `core.operation`; migrate
only stop/restart ownership and lifecycle result vocabulary.

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

Provider breadth is frozen while stable-core hardening is active. Existing
kinds stay available, but `typst.integrations.provider_contract` classifies
each kind as `core`, `supported`, or `experimental`; new kinds require the same
classification, docs, tests, and a deletion or stabilization plan.

## Migration Plan

The current architecture is intentionally migration-friendly rather than a
rewrite target. Refactors should land behind compatibility facades and preserve
the existing public API.

### Stable-Core Implementation Layout

The stable-core implementation layout is the current mostly-flat module layout.
Large file moves and namespace migrations should happen only behind
compatibility facades and targeted contract tests. The stable-core boundary is
behavior-first: project identity, lifecycle ordering, no-project behavior,
output ownership, and reset/recovery semantics must be pinned before
implementation files move.

### Controller Extraction Guardrails

Do not extract broad controller modules before tests pin ownership. Preview is
the current approved extraction because its public facade, pending-handle
contract, resource-manager driver, and callback/native behavior are
covered by stability tests. This stabilization patch hardens behavior through
small compatibility-preserving boundaries:

1. Stabilize boundaries without big moves.
   - `core.result` is the only generic stopped/pending/orphan predicate layer.
   - `project.store` is the ProjectStore facade for live identity, buffer
     ownership, encoded keys, and prune bookkeeping; `project.registry` remains
     the low-level table owner.
   - `project.resolver` resolves candidates without mutating state.
   - `project.attachments` is the BufferAttachment facade for buffer hooks and
     setup reapplication.
   - `typst.project.index_service` owns project-index collection and category
     reads; `typst.project.index_scheduler` owns generation/freshness sync,
     watcher commits, and aggregate-cache metadata. They stay as flat modules
     to avoid adding a broad `project/index/` framework directory.
   - `core.windows` is the shared visible-window lookup primitive.
   - `resources.outputs` is the output lease facade used outside low-level tests.
   - `resources.session` is the project liveness view.
   - `runtime.resource_manager` is the reset, exit, and stop-before-prune
     cleanup entry point.
   - `diagnostics.publisher` is the compiler diagnostic writer.
   - `compiler.fanout` routes compiler-state result consumers.
2. Keep compiler lifecycle in `typst.compiler`.
   - New compile/watch/stop behavior should land in the existing compiler
     lifecycle module or narrower helper modules, not in a new full controller.
   - Keep built-in Typst helpers at their historical paths until tests require a
     real file split.
   - Render already has planner/runner/cache/display/helper splits. Do not keep
     expanding this into a render framework: `typst.workflows.render.runner`
     may retain lifecycle coordination until a concrete bug or deleted
     duplicate path justifies another extraction.
3. Keep preview and viewer lifecycle in tested entry points.
   - `typst.viewer.api` owns artifact opening and viewer source sync for now.
   - `typst.preview.controller` owns preview open/reuse/restart/refresh/stop
     lifecycle.
   - `typst.preview.results`, `typst.preview.pending`,
     `typst.preview.state_machine`, and `typst.preview.backends.*` own preview
     result shape, pending observation, state mutation, and backend adapters.
   - `typst.preview.backends.viewer` is the boring default artifact opener.
     `typst.preview.backends.browser` and `.custom` are explicit advanced
     backends for browser server/source-map behavior and user callbacks.
   - `preview/native/*` may keep native browser/server/session details.
4. Keep navigation and editor implementation files in their existing layout.
   - The current flat navigation/edit modules remain the implementation paths
     for this stabilization patch.
5. Harden the public API before any layout migration.
   - Keep implementation paths movable later, but land each move behind the
     compatibility facade and policy tests first.
6. Shrink broad dependencies only near active work.
   - `typst.core.util` is a compatibility convenience. Replace it with direct
     imports such as `core.path`, `core.buffer`, `core.command`, or
     `core.files` when already editing a module, but do not churn unrelated
     files solely to remove `core.util`.

### Current Boundary Limits

Stable-core hardening should document current owners rather than propose an
expanded controller inventory. New controller modules are allowed only when they
delete duplicated lifecycle code, preserve commands and public APIs, and arrive
with targeted contract tests. Do not add speculative controller namespaces for
compile/watch/viewer workflows just to match an idealized layout.

Command-to-module intent should stay simple for users:

```text
:TypstInfo                  ui.reports -> project/resources/compiler/preview
:TypstSetMain               project.lifecycle
:TypstCompile               typst.compiler
:TypstWatch                 typst.compiler
:TypstStop                  typst.compiler
:TypstStopAll               typst.compiler + runtime.resource_manager
:TypstCompilerForceClear    typst.compiler + resources.outputs
:TypstErrors                diagnostics.quickfix
:TypstView                  viewer.api
:TypstPreview               preview.controller / preview.native
:TypstPreviewStop           preview.controller / preview.native
:TypstToc                   navigation.toc
:TypstPick                  navigation.picker
gf                          navigation.follow
motions/textobjects         edit.*
completion                  completion.*
conceal                     conceal.*
```

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

### Diagnostics Publisher Split

`diagnostics/init.lua` owns namespace policy, source keys, parsing entry points,
and public compatibility methods. `diagnostics/publisher.lua` owns the actual
publish operation: valid-buffer filtering, deep-copying diagnostics into
Neovim, quickfix/list updates, and `TypstDiagnosticsPublished` events. New
diagnostic producers should call the public diagnostics facade, while publisher
tests can target grouped buffer data directly.

### Project Lifecycle Split

`project/lifecycle.lua` is now the compatibility coordinator for attach,
detach, reload, and main-file transitions. Responsibility-specific helpers live
under `project/lifecycle/`:

- `buffers.lua`: buffer autocmd installation, TOC follow hooks, omnifunc, dirty
  changedtick suppression, and reapplying attached buffers after config reload.
- `deferred_import_scan.lua`: deferred import-scan scheduling, tokens, pending
  handles, suggestion recording, command-time suggestion acceptance, and
  reset-visible deferred scan state.
- `events.lua`: attach/detach/prune event payloads and previous-project stop
  handoff.
- `feature_finalize.lua`: post-commit editor/integration finalization for an
  attached buffer, including feature reapplication, Tinymist ensure, and
  deferred-scan scheduling.
- `transition.lua`: the single post-commit transition boundary for event
  emission, bounded transition snapshots, finalization error capture, and
  previous-project stop/prune handoff.
- `reload.lua`: two-phase reload, rollback, failed-candidate cleanup, and
  reload metadata reporting.

Additional lifecycle splits must delete duplicated ownership while preserving
commands, public project APIs, and the scheduled ftplugin attach contract. The
coordinator keeps that idempotence boundary.

### Preview Backend Interface

`typst.preview.controller` owns preview lifecycle decisions. Concrete preview
work lives behind explicit backends under `preview/backends/`: `viewer` for the
boring artifact-to-viewer path, `browser` for advanced native browser/server
work, and `custom` for user callbacks. Do not add a preview backend registry or marketplace layer during
stable-core hardening; new backends must be explicit modules that satisfy the
small `preview.backends.interface` shape and delete duplicated controller logic.

### Compiler Event Pipeline

Compiler user-event emission now flows through `typst.compiler.events`. Built-in
compile/watch paths and provider-neutral state transitions emit normalized
event kinds such as `compile_start`, `cycle_success`, and `compile_stopped`.
That module maps them onto the existing public `TypstCompile*` User events and
filters payload fields so raw process output does not accidentally become part
of the public contract.

Do not introduce a compiler reducer as a standalone framework. If watch
side-effect ordering causes a concrete bug, parser/state may emit narrower
normalized compiler events before diagnostics, artifacts, dependency refresh,
and preview consumers run:

```lua
{ kind = "cycle_start", generation = n, cycle = c }
{ kind = "cycle_success", generation = n, cycle = c, output = path }
{ kind = "cycle_failure", generation = n, cycle = c, diagnostics = by_buffer }
{ kind = "watch_exit", generation = n, result = result }
```

A compiler event reducer should own service transitions and event emission.
Diagnostics, dependency refresh, artifacts, and preview refresh should consume
those normalized events instead of being embedded directly in parser handlers.

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
`stats()` counters. Runtime reset ownership lives in
`runtime.resource_manifest`; cache-registry entries should provide
clear/reload and buffer/window lifecycle methods where appropriate, then
register enough metadata for health/report output to show loaded, unloaded,
clear-capable, reload-capable, forget-capable, detach-capable, and
window-cleanup-capable counts.
