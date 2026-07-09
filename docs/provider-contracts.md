# Provider Contracts

typst.nvim providers are extension points registered with:

```lua
require("typst").providers.register(kind, name, provider)
```

Supported provider kinds are normalized by `typst.integrations.providers`.
Common aliases such as `compile`, `compiler`, `formatter`, `linter`,
`artifact`, `export`, `rendered_preview`, and `view` resolve to their canonical
kind names.

Provider kind stability is deliberately narrower than provider availability.
Core kinds are part of the stable workflow boundary; supported kinds are tested
extension points for the first hardening pass; experimental kinds exist for
early adopters and should not broaden further while stable-core hardening is
active. Experimental does not mean removed: it means the implementation remains
available while its lifecycle/result/API contract is still allowed to change.

- `compiler` - core
- `export` - experimental
- `format` - supported
- `index` - experimental
- `init` - experimental
- `lint` - supported
- `picker` - experimental
- `preview` - experimental
- `render` - experimental
- `semantic` - experimental
- `source_map` - experimental
- `toc` - experimental
- `viewer` - core

The stable-provider target for this phase is intentionally small:
`compiler`, `viewer`, `format`, and `lint`. Preview, render, export,
semantic/source-map, and picker/TOC providers are
advanced or experimental until the compile/view/editing core is boring.

## Semantic Providers

`integrations.semantic.provider` selects the default semantic provider for
provider-backed semantic actions, status reporting, and compiler fallback
diagnostic ownership. It defaults to `"tinymist"`. Registered semantic
provider names, inline provider tables, and callbacks are accepted:

```lua
require("typst").providers.register("semantic", "my-semantic", {
  name = "my-semantic",
  available_for_project = function(project)
    return true
  end,
  workspace_symbols = function(project, opts)
    return { ok = true, symbols = {} }
  end,
})

require("typst").setup({
  integrations = {
    semantic = {
      provider = "my-semantic",
    },
  },
})
```

Semantic provider methods receive the provider-safe project context and the
per-call opts table. Supported method names are `color_info`,
`document_links`, `code_lens`, `workspace_symbols`, `references`,
`rename_preview`, or a generic `run(method, project, opts)` dispatcher.
Providers can also expose `enabled`, `available_for_project`, `available`,
`mode`, `backend`, and `capabilities` for status and diagnostics policy.
Custom providers do not suppress compiler fallback diagnostics merely by being
available. They must opt in with `owns_diagnostics = true`,
`diagnostics = true`, or `capabilities = { diagnostics = true }`.

## Invocation Shapes

Provider methods may complete in one of four ways:

- Return a terminal result synchronously.
- Call the supplied callback with a terminal result.
- Return `{ pending = true, cancel = function(...) ... end }`.
- Return a userdata handle while completing through the callback.

Inline compiler provider tables supplied directly to `setup()` are validated
strictly during setup so missing required methods are reported before command
execution. Registered or dynamically resolved providers that fail validation are
converted to structured `provider_invalid` failures so command paths can report a
provider error without throwing.

The adapter enforces a single terminal result. Late duplicate callbacks after a
timeout, cancellation, or earlier result are logged and ignored.

## Canonical Result Grammar

All provider kinds share this base result and pending-handle grammar. Individual
provider kinds may add fields, but they should not invent a separate success,
failure, cancellation, or pending convention.

```lua
---@class TypstResult
---@field ok? boolean
---@field pending? boolean
---@field code? integer
---@field reason? string
---@field message? string
---@field error? any
---@field stale? boolean
---@field stopped? boolean
---@field forced? boolean
---@field orphaned? boolean
---@field output? string
---@field path? string

---@class TypstPending
---@field pending true
---@field result? TypstResult
---@field on_finish_style? "colon"|"dot"
---@field cancel_style? "colon"|"dot"
---@field cancel? fun(self: TypstPending, opts?: table): boolean, TypstResult?
---@field on_finish fun(self: TypstPending, cb: fun(result: TypstResult, handle?: TypstPending)): TypstPending
```

Expected failure results should use `{ ok = false, reason, message }`. Expected
stop results should use `stopped = true` only after shutdown is confirmed.
Timeouts and unknown external state should not claim `stopped = true`.

When a timeout is configured, userdata handles and pending tables are watchdog
protected. A provider that never calls back receives a synthetic timeout result.
For compiler-provider compile, watch/start, and stop paths, timeout means
"unconfirmed writer": typst.nvim keeps the active provider handle and output
lease recorded because the provider may still write its declared output.
Recovery requires `typst.reset({ force = true })` or
`:TypstCompilerForceClear[!] [project-key]`. Providers that can confirm shutdown
should call back with `{ stopped = true }` or report `idle = true` before the
timeout.

Provider anti-patterns that typst.nvim treats as failures or unconfirmed state:

- returning a pending handle and never calling its finish callback;
- returning a handle-like table without `pending = true` or terminal result
  fields;
- reporting `stopped = true` before the external process or writer is
  confirmed stopped;
- writing to the declared output after a timeout without first reporting a
  retained/orphaned state;
- using dot-style `on_finish(callback)` or `cancel(opts)` without explicitly
  setting `on_finish_style = "dot"` or `cancel_style = "dot"` for the adapter.

### Handle and Result Classification

typst.nvim has two adapter modes:

- **Result mode** is used for provider methods where synchronous returns may
  complete the request. Generic table returns are terminal only when they
  include explicit result fields such as `ok`, `code`, `reason`, `message`,
  `stopped`, `forced`, or `orphaned`. A table with only structural fields such
  as `path`, `output`, `artifacts`, `by_buffer`, or `diagnostics` is not
  terminal by default; individual provider kinds must opt into those shapes or
  normalize them.
- **Handle mode** is used for compiler/watch/start-style methods where the
  returned value may be an active process or custom pending handle. In this
  mode, async table handles must include `pending = true`. Terminal table
  results must be explicit.

Terminal results in handle mode should include at least one terminal field such
as `ok`, `code`, `reason`, `message`, `stopped`, `forced`, or `orphaned`.
Use `{ pending = true }` for pending handles that should expose adapter-managed
timeout/cancel behavior. If a custom handle looks result-shaped, include
`pending = true`; otherwise the adapter reports `invalid_result`. Internal call
sites may supply an explicit handle predicate while migrating legacy handles,
but public providers should not rely on structural fields such as `path`,
`output`, `diagnostics`, or `by_buffer` to imply async state.

Structural-only results are accepted only by provider kinds whose adapters
declare those fields or normalize the table before classification:

| Provider kind | Structural result fields |
| --- | --- |
| `source_map` | `path`, `file`, `filename`, `line`, `column` |
| `lint` | `diagnostics`, `by_buffer` |
| `export` | `path`, `output`, `outputs`, `artifacts` |
| `render` | `path`, `output`, `outputs`, `artifacts` |
| `viewer` | `opened`, `path`, `output` |
| `init` | `path`, `files`, `created`, `template`, `output` |

Examples:

```lua
-- Synchronous result.
return { ok = true, path = "/tmp/main.pdf" }

-- Pending handle. The callback must eventually receive a terminal result.
return {
  pending = true,
  cancel = function(self, opts)
    return true, {
      ok = false,
      stopped = true,
      reason = opts and opts.reason or "cancelled",
    }
  end,
}

-- Pending handle in handle mode. This is not terminal merely because it has path.
return {
  pending = true,
  path = "/tmp/provider-owned-output.pdf",
  cancel = function(self, opts)
    self.process:kill()
    return true, { stopped = true, reason = opts and opts.reason }
  end,
}
```

The shared pending helper used by the adapter, preview exports, and native
preview provides the common `pending`, `result`, `finish(result)`,
`on_finish(callback)`, and `cancel(opts)` behavior. Provider-specific adapters
are still responsible for deciding whether a returned value is a handle or a
terminal result before wrapping it.

Internal pending handles use method-style observation:

```lua
handle:on_finish(function(result) end)
```

typst.nvim-owned handles advertise this with `on_finish_style = "colon"`.
Legacy dot-style handles can be observed only when the adapter explicitly asks
for that calling convention. Cancellation has its own calling convention:
dot-style observation does not imply dot-style cancellation. A handle that needs
`cancel(opts)` instead of `handle:cancel(opts)` must set `cancel_style = "dot"`.
Do not infer dot-vs-colon style from function arity; Lua callbacks often accept
optional arguments, and guessing can register the wrong object as the callback.

The executable provider SDK contract lives in
`typst.integrations.provider_contract`. It exposes stable kind aliases, method
hints, result-shape rules, and `fixture_cases()` for the matrix exercised by
`tests/unit/provider_sdk_matrix_spec.lua`.

The current fixture IDs are:

- `sync_success`
- `sync_failure`
- `callback_success`
- `callback_failure`
- `returned_pending_handle`
- `pending_handle_timeout`
- `cancellation_before_completion`
- `duplicate_callback`
- `thrown_provider_error`
- `malformed_nil_result`

## Terminal Results

Terminal results should be tables. Common fields:

```lua
{
  ok = true,
  code = 0,
  stdout = "",
  stderr = "",
  path = "/tmp/main.pdf",
  artifacts = {},
  stopped = false,
  reason = nil,
  message = nil,
  provider = "provider-name",
}
```

For compiler providers, `typst.compiler.state_machine.normalize` applies these
rules:

- `ok = true` without `code` becomes `code = 0`.
- `ok = false` without `code` becomes `code = 1`.
- `stopped = true` without an error becomes `code = 0`.
- `stdout` and `stderr` are normalized to strings.
- `reason`, `message`, `provider`, `path`, and artifact fields are preserved.

Providers should still include `code` when they are modeling a process exit.
Use `ok` for provider-native success/failure and `reason` for machine-readable
failure classes such as `timeout`, `cancelled`, `invalid_result`, or
`provider_error`.

Process-backed providers that call internal process helpers must pass argv
tables, for example `{ "typst", "compile", main, output }`. Shell strings such
as `"typst compile main.typ"` are rejected with `reason = "invalid_command"` so
providers do not accidentally depend on shell splitting or Neovim internals.

Lint providers may return native Neovim diagnostics grouped by
buffer:

```lua
{
  by_buffer = {
    [bufnr] = {
      {
        lnum = 0,
        col = 0,
        message = "style warning",
        severity = vim.diagnostic.severity.WARN,
      },
    },
  },
}
```

When `by_buffer` is present and `published ~= true`, typst.nvim publishes the
diagnostics under the provider source namespace, updates project diagnostic
bookkeeping, and populates quickfix when requested. Providers that publish
diagnostics themselves must set `published = true`.

Generic provider table returns are terminal only when they include explicit
result fields such as `ok`, `code`, `reason`, `message`, `stopped`, `forced`, or
`orphaned`, or when that provider kind documents an allowed structural return
shape. A table that only has fields like `path`, `output`, or `diagnostics` is
not treated as a completed result by default; provider adapters must opt into
those shapes or normalize them. This avoids confusing cancellable provider
handles with completed work.
If the table exposes `cancel`, `stop`, or `kill` without a terminal result
marker, it must also set `pending = true`; otherwise the adapter reports an
`invalid_result`.

## Cancellation

Pending providers should expose `cancel(opts)` when the underlying operation can
be stopped. typst.nvim forwards cancellation options such as `reason`,
`timeout_ms`, and `kill_timeout_ms` to provider-owned cancel functions. The
method may return:

- `true, terminal_result` when cancellation completed;
- `true, { pending = true }` when shutdown is still in progress;
- `false, terminal_result_or_error` when cancellation was declined or failed.

If a provider has no `cancel()` method, typst.nvim attempts generic process
handle cancellation where possible and otherwise finalizes a local cancelled
result.

Cancellation results are terminal unless they return `{ pending = true }`.
Terminal cancellation flows through the same normalizer and event/status path as
success or failure.

## Compiler Providers

Compiler providers may implement:

```lua
compile(project, callback, run_config)
start(project, callback, run_config)
stop(project, callback)
status(project)
output(project, run_config)
```

Provider author checklist:

- return terminal result tables once, or return `{ pending = true }` while work
  is still owned;
- call the callback exactly once for each terminal compile/watch/stop result;
- expose a cancellable handle when work can outlive the initiating API call;
- report `stopped = true` only when shutdown is confirmed;
- implement `output(project, run_config)` unless the provider deliberately sets
  `outputless = true`;
- expect timeouts, `stopped = false`, and pending stop results to retain state
  until a later terminal callback or explicit force-clear.

`compile` is one-shot. `start` is watch mode. `stop` should eventually call back
with `{ stopped = true }` or a failure result. A timeout or `{ stopped = false }`
does not release output ownership because the provider may still be writing.
`:TypstCompilerForceClear[!] [project-key]` is the user-facing escape hatch for
discarding that unconfirmed state; it releases typst.nvim's lease without
asserting the provider stopped.
`output` is called before compile or watch starts so events, leases, status, and
`:TypstInfo` agree on the planned artifact path. Providers that intentionally
do not produce a document artifact may omit `output()` only when the provider
table sets `outputless = true`; health warns for missing `output()` on any
provider that does not opt into that outputless contract.
Output ownership is enforced by an in-process lease and a file-backed lock
directory under typst.nvim's cache directory. The file-backed lock coordinates
Neovim sessions that share the same cache root; it is not a global filesystem
lock across users, containers, or different XDG/cache roots. If another live
Neovim process owns the same output lock, compile/watch/export/render startup
fails with `reason = "active_output"` and `external_lock = true`. Lock records
from dead processes are recovered before acquiring a new lease. Live PID locks
are never auto-stolen by age alone; use force-clear/manual lock cleanup only
after verifying the owner is gone. Missing, empty, unreadable, or corrupt owner
records are treated as active for a short incomplete-lock grace period so
partially-written acquisitions are not stolen, then recovered.
Use `:TypstLocks` to inspect the lock directory, owner PID, age, output path,
and owner kind. Use `:TypstCleanLocks` for dead-owner or expired incomplete
records, and `:TypstCleanLocks! [output-or-lockdir]` only after confirming a
live or unknown external owner is safe to discard.

Output lock recovery matrix:

| Lock state | Startup behavior | Cleanup behavior |
| --- | --- | --- |
| Current process has an active in-memory lease | blocked by the lease | never removed by cleanup |
| Live foreign PID owns the file-backed lock | `active_output`, `old_live_pid` | bang plus explicit filter only |
| Dead PID owns the file-backed lock | recovered before startup | removed by normal cleanup |
| Owner metadata is missing/empty/corrupt within grace | blocked as active/unknown | kept unless forced with a filter |
| Owner metadata is missing/empty/corrupt after grace | recovered before startup | removed by normal cleanup |
| Same PID lock exists without an in-memory lease | recovered before startup | removed by normal cleanup |

Compile/watch providers must not write outside the output path they reported
unless their own provider contract documents extra artifacts and ownership.

## Native Preview Contract

Native preview is a typst.nvim workflow provider, not a Typst semantic server
or Tinymist export surface. The user-facing selector is:

```lua
preview = {
  provider = "native",
  native = "viewer", -- "viewer" | "browser" | "auto"
}
```

By default, the native provider consumes the compiler service output. When
`preview.export` or `preview.browser.export` selects `profile` or `provider`,
`:TypstPreview` first creates a preview-owned export artifact and displays that
artifact instead. It does not start Tinymist, request Tinymist exports, or infer
semantic source maps.

Target guarantees:

- `preview.native = "viewer"` opens the selected preview output through
  `viewer.open`/viewer presets and emits preview lifecycle events. It is a
  one-shot viewer open; typst.nvim does not claim ownership of the external
  viewer process.
- `preview.native = "browser"` opens a typst.nvim-owned browser preview shell.
  It serves or references the selected preview output, tracks project-local
  preview state, refreshes active browser previews after compile/watch cycles,
  and stops its route/file-shell state when `:TypstPreviewStop` runs.
- `preview.native = "auto"` attempts the browser target first. If browser
  setup or URL opening fails, typst.nvim cleans up the attempted browser session
  and falls back to the viewer target. The failed URL remains available in
  preview state as `last_failed_url`, in `:TypstPreviewStatus!`, and in
  `g:typst_nvim_last_preview_url`.

Relationships to other provider surfaces:

- `compile.*` owns the artifact native preview displays in `compile` export
  mode.
- Preview `profile`/`provider` export modes use the artifact export workflow
  for owned preview outputs without replacing compiler state.
- `viewer.*` owns generic output opening, reload callbacks, and viewer
  forward/inverse hooks. Native viewer preview is a preview command over that
  viewer surface.
- `preview.open`, `preview.stop`, and `preview.refresh` are callback extension
  points. When the active backend is native browser, stop/refresh callbacks are
  composed with native cleanup/refresh rather than replacing them.
- `preview.open` may return `true`, `false`, a structured failure table, or a
  pending handle. Pending opens mark preview state as `opening`, not `active`;
  typst.nvim records active preview state and emits opened events only after
  the pending handle finishes successfully. A pending open that cannot be
  observed or finishes with `ok = false` is recorded as `open_failed`.
- `preview.forward`, `preview.inverse`, and `preview.capabilities` are
  source-sync declarations. Native browser preview does not declare source maps
  by default, and reports unavailable source sync for PDF output unless a
  provider explicitly supports that artifact.

Preview export configuration controls the artifact a native preview target
displays:

```lua
preview = {
  export = {
    mode = "compile",
    profile = nil,
    provider = nil,
    output_format = nil,
    output_name = nil,
    output_dir = nil,
    extra_args = {},
  },
  browser = {
    export = {
      mode = "inherit",
      profile = nil,
      provider = nil,
      output_format = nil,
      output_name = nil,
      output_dir = nil,
      extra_args = {},
    },
  },
}
```

Supported modes are:

- `preview.export.mode = "compile"`: display the current compiler service output
  path. This mode does not run a preview export.
- `profile`: run a named `exports.profiles` entry before display.
- `provider`: invoke an export provider before display. The provider receives
  the same planned-output safety fields as normal artifact exports plus
  preview-specific request metadata.
- `preview.browser.export.mode = "inherit"`: browser-only mode that starts from
  `preview.export`, then applies browser-specific non-nil overrides.

Preview profile/provider exports use typst.nvim artifact ownership and path
leases, but pass `update_compiler_output = false` and `producer = "preview"`;
they do not replace the project compiler output. If no preview export
`output_dir` is configured, typst.nvim writes into the preview cache with a
project-specific `output_name` so preview exports do not silently overwrite
document builds. The resulting artifact is recorded on preview state as
`active_output`/`last_output` and the effective export summary is recorded as
`active_export`/`last_export`.

For now, `preview.export.provider` intentionally reuses the artifact export
provider contract instead of introducing a separate preview-export provider
kind. Providers can distinguish preview calls from document exports by checking
these fields in the `opts` table:

```lua
{
  preview = true,
  preview_export = true,
  preview_target = "viewer" or "browser",
  producer = "preview",
  update_compiler_output = false,
}
```

The dedicated provider kind should be introduced only if preview rendering needs
semantics that the artifact export contract cannot represent cleanly.

Native browser preview refreshes are generation-guarded. If a newer refresh
export finishes before an older refresh export, the older result is reported as
`stale_preview_refresh` and cannot replace the active route, shell state, or
preview output.

Browser opening is preflighted before typst.nvim reports success. With
`preview.browser.app = nil` and `preview.browser.commands = nil`, typst.nvim
opens the URL through `vim.ui.open()` when available, then the OS default URL
opener such as `open`, `xdg-open`, or Windows shell openers.
`preview.browser.app` is the high-level browser picker for local app selection;
known selectors include `"firefox"`, `"chrome"`, `"chromium"`, `"safari"`,
`"edge"`, `"brave"`, `"opera"`, `"vivaldi"`, and `"arc"`, and unknown names are
treated as macOS app names or executable names. Without a custom
`preview.browser.open` callback, `preview.browser.commands` can provide ordered
opener candidates; `{url}` is replaced with the preview URL, and the URL is
appended when no placeholder is present. Configure commands only when the
default opener or `app` picker is wrong for the environment, such as WSL, SSH,
remote Neovim sessions, or app-specific browser checks:

The native browser server is local by default (`127.0.0.1`) and is bounded for
accidental local misuse: request headers are capped, idle request reads time out,
artifact responses larger than `preview.browser.max_artifact_bytes` return
`413 Payload Too Large`, and under-cap artifacts are streamed in bounded chunks.
The listener stops when the last browser preview route is cleared, on reset, and
on force-reset cleanup. Set `preview.browser.max_artifact_bytes = 0` only for
trusted local use; it disables the artifact size cap.
Non-loopback browser routes require `preview.browser.allow_remote = true` and
are tokenized by default with `preview.browser.token = "auto"`. Providers and
open callbacks should treat the full URL as opaque and preserve its query
string.

```lua
preview = {
  native = "browser",
  browser = {
    host = "127.0.0.1",
    -- Optional local browser picker:
    -- app = "chrome",
    -- Lower-level opener override for remote environments:
    commands = {
      { "wslview", "{url}" },
    },
  },
}
```

`preview.browser.performance = "safari"` is an opt-in conservative mode for
browser targets that lag under frequent reloads. It uses file-shell transport,
slower polling, and a reload throttle. `preview.browser.performance = "fast"`
keeps normal transport but lowers the shell poll interval. For explicit
control, set `preview.browser.reload_throttle_ms`; manual
`:TypstPreviewReload` bypasses throttling.

Native browser preview source synchronization is capability-gated. The native
browser shell does not infer source maps from Tinymist and does not claim
SyncTeX-style support for normal Typst PDF output. The default
`preview.source_maps.provider = "typst-query"` can resolve SVG browser previews
by querying Typst's own locatable block positions and matching them back to
local source text. For PDFs, unsupported formats, or unmatchable documents,
native preview reports no browser source-sync capability unless another
provider or explicit hook supplies it. The browser shell displays the
capability status from `preview.source_maps` state instead of pretending all
preview formats can be clicked back to Typst source. Legacy `preview.forward`,
`preview.inverse`, and `preview.capabilities` remain supported. New source-map
providers should prefer the explicit extension namespace:

```lua
preview = {
  source_maps = {
    provider = "typst-query", -- label, provider table, callback, or module name
    forward = nil, -- fun(project, position, opts)
    inverse = nil, -- fun(project, source_location, opts)
    capabilities = {
      forward = false,
      inverse = false,
      source_maps = false,
    },
  },
}
```

The experimental provider kind for real source-map integrations is
`source_map`.
Aliases include `source_maps`, `sourcemap`, `sourcemaps`,
`preview_source_map`, and `preview_source_maps`.

Source-map providers may implement:

```lua
generate(project, request, callback)
resolve(project, request, callback)
forward(project, request, callback)
inverse(project, request, callback)
browser_inverse(project, request, callback)
run(project, request, callback)
```

`forward` receives a request with `{ action = "forward", position, line,
column, main, root, output }`. `inverse` receives an explicit source location
request from Neovim commands. `browser_inverse` receives click events from the
native browser server shell:

```lua
{
  action = "browser_inverse",
  event = "click",
  output = "/path/to/preview.svg",
  page = 1,
  x = 128,
  y = 256,
  viewport_width = 1024,
  viewport_height = 768,
  target = "svg",
}
```

Browser inverse providers should return a source location:

```lua
{
  path = "/path/to/source.typ",
  line = 12,
  column = 4,
}
```

Native browser click sync is available only in server transport mode. The
file-shell fallback can display source-sync status from the state file, but it
cannot call back into Neovim because there is no local HTTP route.

`preview.follow_buffer = true` makes one active native browser preview follow
the focused Typst buffer's resolved project/main. typst.nvim reassigns the
existing browser route to the new project output instead of opening another
browser tab. When multiple native browser previews are active, follow-buffer is
skipped to avoid stealing ownership from another project.

## Project Contexts

External providers receive project snapshots by default. Treat those snapshots
as read-only request context. Do not retain them as mutable state, and do not
expect changes to propagate back to typst.nvim's live project registry.

## Test Fixtures

New provider kinds or major provider behavior changes should add fixtures for:

- synchronous success and synchronous failure;
- callback success and callback failure;
- returned pending handle success;
- pending handle timeout without callback;
- cancellation before completion;
- duplicate callback after terminal result;
- thrown provider error;
- malformed or nil result.

The executable conformance matrix lives in
`typst.integrations.provider_contract`. Every provider kind listed in this
document must be covered by the shared adapter fixtures below, plus any
kind-specific integration tests required by its lifecycle:

| Fixture id | Required edge case |
| --- | --- |
| `sync_success` | synchronous success |
| `sync_failure` | synchronous failure |
| `callback_success` | asynchronous callback success |
| `callback_failure` | asynchronous callback failure |
| `returned_pending_handle` | returned pending handle |
| `pending_handle_timeout` | timeout or never-callback pending handle |
| `cancellation_before_completion` | cancel before completion |
| `duplicate_callback` | stale or duplicate terminal callback |
| `thrown_provider_error` | thrown provider error |
| `malformed_nil_result` | malformed or nil result |

The release `provider-matrix` gate runs the shared SDK fixtures for compiler,
preview/export/render, source-map, viewer, formatter, linter, and
workflow providers even when those kinds are experimental. A provider behavior
change is incomplete unless it updates the conformance matrix, docs, and
focused fixture coverage in the same patch.
