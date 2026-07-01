# Provider Contracts

typst.nvim providers are extension points registered with:

```lua
require("typst").providers.register(kind, name, provider)
```

Supported provider kinds are normalized by `typst.integrations.providers`.
Common aliases such as `compile`, `compiler`, `formatter`, `linter`,
`artifact`, `export`, `rendered_preview`, and `view` resolve to their stable
kind names.

Stable provider kinds are:

- `bench`
- `compiler`
- `coverage`
- `eval`
- `export`
- `format`
- `grammar`
- `index`
- `init`
- `lint`
- `picker`
- `preview`
- `profile`
- `render`
- `semantic`
- `source_map`
- `test`
- `toc`
- `viewer`

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
- Return a raw handle or userdata while completing through the callback.

The adapter enforces a single terminal result. Late duplicate callbacks after a
timeout, cancellation, or earlier result are logged and ignored.

When a timeout is configured, raw handles and pending tables are watchdog
protected. A provider that never calls back receives a synthetic timeout result.
For compiler-provider compile, watch/start, and stop paths, timeout means
"unconfirmed writer": typst.nvim keeps the active provider handle and output
lease recorded because the provider may still write its declared output.
Recovery requires `typst.reset({ force = true })` or
`:TypstCompilerForceClear[!] [project-key]`. Providers that can confirm shutdown
should call back with `{ stopped = true }` or report `idle = true` before the
timeout.

### Handle and Result Classification

typst.nvim has two adapter modes:

- **Result mode** is used for provider methods where a returned table normally
  means completed work. Tables with `ok`, `code`, `reason`, `message`,
  `stopped`, `output`, `path`, `artifacts`, `by_buffer`, or `diagnostics` are
  treated as terminal results unless `pending = true` is present.
- **Handle mode** is used for compiler/watch/start-style methods where the
  returned value may be an active process or custom pending handle. In this
  mode, tables with only handle-like fields such as `path`, `output`,
  `diagnostics`, or `by_buffer` remain handles. Terminal table results must be
  explicit.

Terminal results in handle mode should include at least one terminal field such
as `ok`, `code`, `reason`, `message`, `stopped`, `forced`, or `orphaned`.
Use `{ pending = true }` for pending handles that should expose adapter-managed
timeout/cancel behavior. If a custom handle looks result-shaped, either include
`pending = true` or ensure the call site supplies an explicit handle predicate.

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

-- Raw handle in handle mode. This is not terminal merely because it has path.
return {
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
for that calling convention. Do not infer dot-vs-colon style from function
arity; Lua callbacks often accept optional arguments, and guessing can register
the wrong object as the callback.

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
- `raw_handle_timeout`
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

For compiler providers, `typst.compiler.result.normalize` applies these rules:

- `ok = true` without `code` becomes `code = 0`.
- `ok = false` without `code` becomes `code = 1`.
- `stopped = true` without an error becomes `code = 0`.
- `stdout` and `stderr` are normalized to strings.
- `reason`, `message`, `provider`, `path`, and artifact fields are preserved.

Providers should still include `code` when they are modeling a process exit.
Use `ok` for provider-native success/failure and `reason` for machine-readable
failure classes such as `timeout`, `cancelled`, `invalid_result`, or
`provider_error`.

Lint and grammar providers may return native Neovim diagnostics grouped by
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

`compile` is one-shot. `start` is watch mode. `stop` should eventually call back
with `{ stopped = true }` or a failure result. A timeout or `{ stopped = false }`
does not release output ownership because the provider may still be writing.
`:TypstCompilerForceClear[!] [project-key]` is the user-facing escape hatch for
discarding that unconfirmed state; it releases typst.nvim's lease without
asserting the provider stopped.
`output` is called before compile or watch starts so events, leases, status, and
`:TypstInfo` agree on the planned artifact path.

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
- `preview.forward`, `preview.inverse`, and `preview.capabilities` are
  source-sync declarations. Native browser preview does not declare source maps
  by default, and reports unavailable source sync for PDF output unless a
  provider explicitly supports that artifact.
- `preview.provider = "typst-preview.nvim"` is explicit compatibility
  delegation to that plugin's commands. It is not selected automatically just
  because those commands exist.

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

The stable provider kind for real source-map integrations is `source_map`.
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
- raw handle timeout without callback;
- cancellation before completion;
- duplicate callback after terminal result;
- thrown provider error;
- malformed or nil result.
