# Architecture Notes

This document records internal contracts that keep typst.nvim maintainable as
project, compiler, preview, diagnostics, completion, conceal, and provider
features grow. Public API details live in `API.md` and
`docs/provider-contracts.md`; this file is about ownership and lifecycle rules.

## Workflow-First Target Layout

The long-term layout should make typst.nvim read like a Typst workflow
environment, not a bag of feature files. The important questions are:

1. Who owns project identity?
2. Who owns live resources?
3. Who owns generated outputs?
4. Who owns compiler/watch lifecycle?
5. Who publishes diagnostics?
6. Which modules are public API versus internal implementation?

The target top level is:

```text
lua/typst/
  api/             Stable Lua facade and API spec.
  runtime/         Setup, reset, autocmds, command registration, health.
  config/          Defaults, validation, profiles, schema/docs generation.
  core/            Pure primitives: result, process, operation, path, events, cache.
  project/         Root/main resolution, registry, lifecycle, services, index.
  resources/       Project resource/session ownership, output leases, cleanup.
  compiler/        Compile/watch controller, providers, Typst CLI backend, watch parser.
  diagnostics/     Policy, parser, publisher, quickfix/location list.
  viewer/          Output viewers and source-sync capabilities.
  preview/         Native/custom/delegated preview sessions and source sync.
  navigation/      TOC, gf/follow, labels, citations, symbols, pickers.
  editor/          Motions, text objects, transforms, folds, indent, formatexpr.
  completion/      Completion sources and frontends.
  conceal/         Conceal matching, rendering, custom rules, inspection.
  bibliography/    BibTeX/Hayagriva parsing, diagnostics, citation workflows.
  metadata/        Generated Typst metadata, package/font/style data.
  workflows/       Export, render, eval, template, clean, lint, format, dev tasks.
  integrations/    Tinymist, provider adapter, picker adapters, external plugins.
  ui/              Commands, reports, status, notifications.
  internal/        Debugging, invariant checks, compatibility helpers.
```

The ideal expanded target is:

```text
lua/typst/
  init.lua

  api/
    init.lua
    spec.lua
    exports.lua
    runtime.lua
    contract.lua

  runtime/
    setup.lua
    reset.lua
    autocmds.lua
    commands.lua
    health.lua
    ftplugin.lua
    state.lua

  config/
    init.lua
    defaults.lua
    validate.lua
    schema.lua
    profiles.lua
    docs.lua

  core/
    result.lua
    async.lua
    pending.lua
    operation.lua
    process.lua
    path.lua
    buffer.lua
    files.lua
    cache.lua
    scan_cache.lua
    cache_registry.lua
    events.lua
    log.lua
    telemetry.lua
    coordinates.lua
    lsp_request.lua
    tables.lua
    text.lua
    xdg.lua

  project/
    init.lua
    registry.lua
    resolver.lua
    model.lua
    lifecycle.lua
    context.lua
    root.lua
    main_file.lua
    dependencies.lua
    graph/
      init.lua
      sources.lua
      match.lua
      dependencies.lua
    index/
      init.lua
      collector.lua
      cache.lua
      parser.lua
      files.lua
      invalidation.lua
    services/
      init.lua
      compiler.lua
      preview.lua
      viewer.lua
      diagnostics.lua
      artifacts.lua
      operations.lua
      graph.lua
      index.lua
      invalidation.lua

  resources/
    session.lua
    outputs.lua
    cleanup.lua
    operations.lua
    leases.lua
    retained.lua

  compiler/
    init.lua
    api.lua
    result.lua
    provider.lua
    provider_binding.lua
    command.lua
    typst_compile.lua
    typst_watcher.lua
    typst_process.lua
    dependencies.lua
    output_path.lua
    output.lua
    watch/
      runner.lua
      state.lua
      parser.lua
      fixtures.lua
    generic.lua
    lifecycle.lua
    events.lua

  diagnostics/
    init.lua
    policy.lua
    parser.lua
    publisher.lua
    quickfix.lua
    count.lua

  preview/
    init.lua
    native/
      init.lua
      browser.lua
      server.lua
      session.lua
      transport.lua
    provider.lua
    follow_buffer.lua
    source_sync.lua
    events.lua
    capabilities.lua

  viewer/
    init.lua
    api.lua
    provider.lua
    generic.lua
    generic_helpers.lua
    source_sync.lua
    capabilities.lua

  navigation/
    toc.lua
    toc_collect.lua
    toc_state.lua
    toc_window.lua
    toc_quickfix.lua
    follow.lua
    follow_context.lua
    follow_lsp.lua
    follow_patterns.lua
    picker.lua
    picker_backends.lua
    picker_items.lua
    symbols.lua
    labels.lua
    citations.lua
    references.lua
    links.lua

  edit/
    init.lua
    treesitter.lua
    context.lua
    motions/
    textobjects/
    folds.lua
    indent.lua
    imaps.lua
    match_highlight.lua
    format_expr.lua
    surround.lua
    transforms/
      markup.lua
      raw.lua
      math.lua
      list.lua
      function.lua
      label.lua
      reference.lua

  completion/
    init.lua
    context.lua
    sources/
      lsp.lua
      stdlib.lua
      project.lua
      packages.lua
      paths.lua
      bibliography.lua
      labels.lua
      citations.lua
      fonts.lua
      colors.lua
      raw.lua
      csl.lua
      parameters.lua
    frontends/
      omnifunc.lua
      native.lua
      cmp.lua
      blink.lua
    cache.lua

  conceal/
    init.lua
    controller.lua
    matches.lua
    render.lua
    match_query.lua
    rules.lua
    lookup.lua
    shadows.lua
    syntax.lua
    symbols.lua
    math.lua
    emoji.lua
    custom.lua
    inspect.lua

  bibliography/
    init.lua
    parser.lua
    bibtex.lua
    hayagriva.lua
    diagnostics.lua
    edit.lua
    workflow.lua
    attachments.lua

  metadata/
    init.lua
    symbols.lua
    packages.lua
    fonts.lua
    csl.lua
    raw_languages.lua
    cache.lua

  workflows/
    artifacts.lua
    export.lua
    render.lua
    eval.lua
    template.lua
    clean.lua
    lint.lua
    format.lua
    grammar.lua
    development.lua

  integrations/
    providers.lua
    provider_adapter.lua
    semantic_provider.lua
    tinymist/
      init.lua
      clients.lua
      requests.lua
      commands.lua
      features.lua
      code_actions.lua
      symbols.lua
    coc.lua
    treesitter.lua
    telescope.lua
    fzf_lua.lua
    snacks.lua

  ui/
    commands/
      init.lua
      compiler.lua
      project.lua
      preview.lua
      viewer.lua
      navigation.lua
      editing.lua
      tools.lua
      complete.lua
      util.lua
    reports.lua
    status.lua
    log.lua
    notify.lua
    select.lua

  internal/
    debug.lua
    compat.lua
    invariants.lua
```

This is a target, not a mandate for a single PR. Move ownership first and files
second. A file move is acceptable only after tests pin the boundary it
represents.

## Top-Level Mental Model

When a maintainer opens `lua/typst/`, the directories should communicate the
product workflow and ownership model:

```text
api          public Lua surface
runtime      setup/reset/autocmd/commands/health
config       configuration
core         reusable primitives
project      root/main/project identity
resources    live resources and cleanup
compiler     compile/watch
diagnostics  diagnostic parsing/publishing
viewer       open generated output
preview      live preview sessions
navigation   toc/gf/pickers/labels/citations
editor       motions/textobjects/format/folds/indent
completion   completion sources/frontends
conceal      visual conceal engine
bibliography bibliography-specific support
metadata     generated Typst metadata
workflows    export/render/eval/lint/format/etc.
integrations external plugin/tool adapters
ui           command/report/status presentation
internal     debug/compat/invariant checks
```

The ownership model behind that layout is:

```text
project owns identity
resources centralizes liveness migration
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

Compiler and preview are core workflows. Only external tool/plugin adapters
belong under `integrations/`.

Do not move files before tests pin ownership. The layout should follow
boundaries with regression coverage:

```text
project resolver does not mutate registry
project.store owns live project identity
project.attachments owns buffer hook installation
resources session decides project activity
outputs facade owns leases
resources.supervisor is the reset/prune/exit cleanup entry point
diagnostics publisher is the only diagnostic writer
compiler.fanout routes compiler-state post-result consumers
typst.compiler decides stop/timeout semantics
typst.integrations.typst_preview decides delegated preview stop semantics
typst.viewer.api decides viewer/source-sync command semantics
```

## Hard Ownership Boundaries

Core modules should be boring and dependency-light. `core/` must not know about
Typst projects, preview, compiler, diagnostics, or UI. It owns reusable
primitives such as process shutdown, pending handles, path helpers, generic
result predicates, logging, events, and caches. Compiler-specific result
normalization should eventually move from `core.result` into
`compiler/result.lua`; `core.result` should retain only generic result predicates
and constructors.

Project modules own identity, not live resources. They answer root, main, key,
buffer membership, dependency graph, index state, and service-table existence.
They should not know how to kill a compiler, stop a preview server, release an
output lease, or publish diagnostics.

Resources modules are the liveness migration boundary. Runtime reset, exit
cleanup, and stop-before-prune orchestration should go through
`resources.supervisor` (`resources.cleanup` is a compatibility alias) so project
lifecycle code stops learning backend-specific compiler, preview, operation,
diagnostics, or output details. This is still a facade over some older lifecycle
code; ownership is being migrated behind it.

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
should call `vim.diagnostic.set` for compiler/lint/grammar diagnostics. Parser,
policy, quickfix, and count helpers should feed that publisher or clearly
document an exception.

Viewer and preview are separate workflows. `typst.viewer.api` owns viewer
commands and preview-facing public command orchestration. A viewer opens or
controls existing artifacts. `typst.integrations.typst_preview` owns delegated
`typst-preview.nvim` compatibility, while `preview/native/*` owns native browser
preview details. Do not extract full preview/viewer controllers before the
stable-core boundary is pinned. Source-sync capability reporting should make
this distinction explicit.

Navigation modules return item lists and jump actions. UI modules decide how to
show them, and integrations supply optional semantic data. Navigation should not
depend directly on Telescope, fzf-lua, Snacks, or other picker implementations.

Editor modules own editing behavior: motions, text objects, transforms, folds,
indent, insert mappings, match highlighting, and formatexpr. Project lifecycle
may apply or detach editor hooks, but it should not know their internal behavior.

Workflows own user-triggered jobs that are not the main compiler loop: export,
render, eval, template init, clean, lint, format, grammar, and development tools.
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
`setup()` against the setup-time cwd. Resolver code must not reinterpret those
keys against the live cwd, because `:cd`/`:lcd` must not change project
identity. Resolver candidates carry `main_confidence`: explicit sources are
high confidence, import-scan/existing graph matches are medium confidence, and
fallback guesses such as current-buffer or nested `main.typ` are low confidence.
User-facing compile/watch paths warn once per project before using the nested
`main.typ` heuristic.

The resolver may read bounded source snippets and filesystem metadata, but it
must not start compiler, preview, Tinymist, or watcher work. Attach/lifecycle
code owns side effects after resolution succeeds. Attach defers import scanning
and marks the attached project with `resolution_pending = "import_scan"` while a
scheduled scan settles; command-time resolution forces a pending scan before
compiler, preview, or navigation work starts. Import scanning still uses the
same synchronous scanner when it runs, so it is capped by candidate count,
ancestor depth, and filesystem entry count. It uses a short-lived
path/root/config/root-metadata cache, and roots that exceed the entry cap abort
the import-scan attempt instead of using partial scan results.

Project identity is keyed by root plus main. Modules should use project API
snapshots for observation and service controllers for mutation instead of
constructing keys by hand.

## Result and Resource Boundaries

`core/result.lua` defines shared result constructors and predicates for
compiler, provider, preview, and operation lifecycle code. In particular,
`is_confirmed_stopped()` is the only generic predicate that should release owned
resources, while timeout/orphaned/pending stop results remain unconfirmed.

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

### Stable-Core Implementation Layout

The stable-core implementation layout is the current flat module layout. No
large file moves, controller extractions, or namespace migrations should happen
inside this stabilization patch. The stable-core boundary is behavior-first:
project identity, lifecycle ordering, no-project behavior, output ownership,
and reset/recovery semantics must be pinned before implementation files move.

### No Controller Extraction Before Stable

Do not move files or extract new controller modules before tests pin ownership.
This stabilization patch hardens behavior in the existing modules:

1. Stabilize boundaries without big moves.
   - `core.result` is the only generic stopped/pending/orphan predicate layer.
   - `project.store` is the ProjectStore facade for live identity, buffer
     ownership, encoded keys, and prune bookkeeping; `project.registry` remains
     the low-level table owner.
   - `project.resolver` resolves candidates without mutating state.
   - `project.attachments` is the BufferAttachment facade for buffer hooks and
     setup reapplication.
   - `project.index.*` is the migration namespace for static-index modules;
     old `project.index_*` files stay as compatibility entry points until the
     large files can move without churn.
   - `core.windows` is the shared visible-window lookup primitive.
   - `resources.outputs` is the output lease facade used outside low-level tests.
   - `resources.session` is the project liveness view.
   - `resources.supervisor` is the reset, exit, and stop-before-prune cleanup
     entry point while ownership migrates behind it.
   - `diagnostics.publisher` is the compiler diagnostic writer.
   - `compiler.fanout` routes compiler-state result consumers.
2. Keep compiler lifecycle in `typst.compiler`.
   - New compile/watch/stop behavior should land in the existing compiler
     lifecycle module or narrower helper modules, not in a new full controller.
   - Keep built-in Typst helpers at their historical paths until tests require a
     real file split.
3. Keep preview and viewer lifecycle in existing entry points.
   - `typst.viewer.api` owns artifact opening and viewer source sync for now.
   - `typst.integrations.typst_preview` owns delegated preview compatibility for
     now.
   - `preview/native/*` may keep native browser/server/session details.
4. Keep navigation and editor implementation files in their existing layout.
   - The current flat navigation/edit modules remain the implementation paths
     for this stabilization patch.
5. Harden the public API before any future layout migration.
   - Keep implementation paths movable later, but do not move them in this
     patch.

### Post-Stable Target Boundaries

After the stable-core contract is pinned, narrower controller modules remain
valid long-term extraction targets when tests show the ownership boundary is
stable. `compiler.controller` can become the compile/watch/stop/output owner,
`preview.controller` can own native/delegated preview lifecycle, and
`viewer.controller` can own viewer open/forward/inverse behavior. Those are
post-stable targets, not prerequisites for this stabilization patch.
   - Expose workflow namespaces deliberately: project, compiler, viewer,
     preview, diagnostics, navigation, edit, completion, conceal, bibliography,
     metadata, providers.

Command-to-module intent should stay simple for users:

```text
:TypstInfo                  ui.reports -> project/resources/compiler/preview
:TypstSetMain               project.lifecycle
:TypstCompile               typst.compiler
:TypstWatch                 typst.compiler
:TypstStop                  typst.compiler
:TypstStopAll               typst.compiler + resources.supervisor
:TypstCompilerForceClear    typst.compiler + resources.outputs
:TypstErrors                diagnostics.quickfix
:TypstView                  viewer.api
:TypstPreview               integrations.typst_preview / preview.native
:TypstPreviewStop           integrations.typst_preview / preview.native
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
`stats()` counters. New cache owners should provide reset/clear/reload and
buffer/window lifecycle methods where appropriate, then register enough metadata
for health/report output to show loaded, unloaded, reset-capable,
clear-capable, reload-capable, forget-capable, detach-capable, and
window-cleanup-capable counts.
