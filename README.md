# typst.nvim

`typst.nvim` is a project-aware Typst workflow plugin for Neovim.

The goal is to bring the useful parts of VimTeX's workflow model to Typst:
main-file discovery, project state, asynchronous compilation, diagnostics,
logs, viewers, previews, navigation, and Typst-native editing operations.

The plugin core is Lua. Rust is used only for release-time tooling that needs
Typst's own crates, such as generating bundled metadata artifacts.

## Status

This repository is in an early reset phase.

Feature stability is intentionally tiered:

- Stable workflow core: project attachment, explicit mains, compile/watch/stop,
  diagnostics, status/info, output leases, and public API/event compatibility.
- Stabilizing editor UI: completion frontends, navigation/pickers, conceal,
  structural editing, native preview, and Tinymist semantic helpers.
- Experimental/provider surface: custom providers, export/eval/profile/test
  workflows, render fragments, and compatibility shims for external preview
  plugins.

Implemented workflow groups:

- Project state keyed by `(root, main)`, explicit main control, reload/reset,
  cache clearing, health, status, logs, resource blockers, and stable public
  API symbol reporting.
- Built-in Typst compile/watch/stop, generated-output leases, file-backed
  output locks, diagnostics publication, quickfix, viewer open/reload, and
  native preview.
- Tinymist-aware semantic helpers, completion frontend adapters, TOC/pickers,
  navigation/follow, folds, conceal, motions, text objects, structural editing,
  bibliography diagnostics, package resources, symbols, and metadata.
- Provider-backed compile/view/preview/source-map/export/render/eval/format/
  lint/grammar/profile/test/bench/coverage workflows with documented timeout,
  cancellation, and retained-resource behavior.
- CI gates for unit, integration, policy, stable-core lifecycle, docs/API
  contracts, provider matrix, Windows edges, no Tree-sitter, fake Typst,
  frontend smoke, startup profiling, and large-project performance.

The full command inventory is in `:help typst-commands`; public Lua
compatibility is in [API.md](API.md), and workflow configuration examples live
under [docs/examples](docs/examples).

## Requirements

- Neovim 0.11+
- `typst` executable in `PATH`

Optional integrations:

- Tinymist through Neovim's built-in LSP client. The default `auto` mode follows
  the rustaceanvim ownership model: typst.nvim starts or reuses `tinymist` when
  available unless coc.nvim appears active. Coc users, including
  `coc-tinymist` users, should configure Tinymist on the Coc side with
  `tinymist.serverPath`/`tinymist.serverArgs`; typst.nvim's
  `integrations.tinymist.path` only configures Neovim's built-in LSP startup.
  Use `"detect"` to only query an already-attached nvim-lsp Tinymist client,
  `"off"` to stay on fallback paths, or `"start"` to force
  typst.nvim-managed nvim-lsp startup even when Coc is present. Set
  `integrations.tinymist.client_names` to detect custom nvim-lsp wrapper
  client names. `:checkhealth
  typst` reports the selected mode, detected native Tinymist clients,
  advertised capabilities, and the Coc skip reason.
- `typst-preview.nvim` only when explicitly selected as a compatibility preview
  provider for its source synchronization commands
- Telescope, fzf-lua, fzf.vim, or Snacks for `:TypstPick` UI
- [SeniorMars/tree-sitter-typst](https://github.com/SeniorMars/tree-sitter-typst)
  for structural editing and query-backed features

## Choose your workflow

Start with the smallest setup that matches how you edit Typst, then add
integrations only when you need them.

| Workflow | Use when | Setup notes |
| --- | --- | --- |
| Built-in Typst CLI | You want project detection, `:TypstCompile`, `:TypstWatch`, diagnostics parsed from Typst output, and `:TypstView`. | Install `typst` and run `:checkhealth typst`. This path works without Tinymist or preview plugins. |
| Typst CLI + Tinymist | You want LSP-backed completion, references, rename, color/code-lens actions, or Tinymist diagnostics. | Keep `integrations.tinymist.lsp = "auto"` for typst.nvim-managed nvim-lsp startup, use `"detect"` to reuse an existing nvim-lsp client, or use Coc's own Tinymist settings when coc.nvim owns the LSP session. |
| Native preview | You want typst.nvim to open the compiler output in a viewer or browser shell. | Keep `preview.provider = "native"`. The default `preview.native = "viewer"` opens the current compiler output; set `"browser"` for the local browser shell. |
| typst-preview.nvim compatibility | You already use typst-preview.nvim and want typst.nvim project commands around it. | Set `preview.provider = "typst-preview.nvim"`. typst.nvim delegates preview open/stop/source-sync commands instead of pretending to own that backend. |
| Custom providers | You wrap another compiler, viewer, formatter, linter, renderer, or preview backend. | Register providers with `require("typst").providers.register(...)` and follow [docs/provider-contracts.md](docs/provider-contracts.md), especially timeout and pending-handle behavior. |

Useful entry points:

- `:help typst-projects` for root/main resolution and project ownership.
- `:help typst-compile` for compile/watch, output ownership, and profiles.
- `:help typst-troubleshooting` for runtime diagnosis.
- [API.md](API.md) for the normative Lua compatibility contract.
- [docs/api.md](docs/api.md) for Lua API usage notes and async result shapes.
- [docs/architecture-lifecycle.md](docs/architecture-lifecycle.md) for
  maintainer lifecycle state machines and invariants.
- [docs/provider-contracts.md](docs/provider-contracts.md) for provider callbacks,
  pending handles, cancellation, and stop timeout semantics.
- [docs/stability-policy.md](docs/stability-policy.md) for release,
  compatibility, and deprecation policy.

## Stability and limitations

| Surface | Status | Notes |
| --- | --- | --- |
| User commands | Supported, but still early-reset quality. | Commands are the preferred automation surface while internals settle. |
| Installed Lua namespaces such as `typst.project`, `typst.compiler`, diagnostics, viewer, completion, conceal, bibliography, and metadata | Only exact dotted symbols in the stable-symbol block of [API.md](API.md) are stable. | API stability is checked in CI; [docs/api.md](docs/api.md) explains usage tiers and examples. |
| Provider contracts | Supported but intentionally strict. | Compiler providers that may write output must call back, expose cancellation, or accept retained leases until force-clear. |
| Service tables, project lifecycle internals, resource/session internals | Internal. | These may move as ownership boundaries harden. Use commands or documented API wrappers instead. |

Feature stability is grouped by workflow, not by module directory:

| Group | Includes | Expectation |
| --- | --- | --- |
| Core workflow | Setup, project discovery, main-file control, compile/watch/stop, diagnostics, viewer dispatch, status/info/log/cache/lock commands. | Supported user workflow; regressions should be treated as bugs. |
| Editor workflow | Completion adapters, TOC/pickers, folds, motions, text objects, conceal, formatting, lint, grammar, and structural transforms. | Supported, but quality can depend on Tree-sitter, Typst CLI, Tinymist, and configured providers. |
| Integration workflow | Tinymist, native preview, typst-preview.nvim delegation, custom providers, export/render/eval/profile/test/bench/coverage helpers. | Supported where configured; provider contracts may still tighten before a stable release. |
| Lua API | Exact dotted symbols in the stable-symbol block of [API.md](API.md). | Stable at the current API level. Installed helpers outside that list are experimental. |
| Internals | Service tables, resolver/index/preview sessions, resource supervision, generated metadata loaders, and cache registries. | Internal; use commands or documented Lua wrappers instead of depending on these shapes. |

Known limitations:

- Human `typst watch` output is best-effort parsed. Prefer structured provider
  output where available, and check `:TypstInfo!` when watch status looks stale.
- Normal Typst PDF output does not provide SyncTeX-style source sync. Forward
  and inverse search depend on viewer, preview, or source-map provider
  capabilities.
- Import scanning is bounded, cached briefly, and deferred from buffer attach.
  Commands force any pending scan before they compile/preview. Once
  `project.import_scan_max_entries` is reached, typst.nvim abandons that
  import-scan attempt and falls back to later main-file heuristics; disable
  `project.import_scan` entirely in remote trees if even deferred scan latency
  is not acceptable.
- Rich conceal changes window-local `conceallevel` while enabled. Disable
  `conceal.enabled` or use `:TypstConcealDisable` for a plain-source workflow.

## Usage

Start with the core loop:

```vim
:checkhealth typst
:TypstInfo
:TypstCompile
:TypstView
```

For continuous editing, use watch mode:

```vim
:TypstWatch
:TypstStatus
:TypstStop
```

For multi-file projects, make the main file explicit when automatic resolution
is not enough:

```vim
:TypstSetMain path/to/main.typ
:TypstEditMain
:TypstFiles
```

For browser preview and source-sync-capable integrations:

```vim
:TypstPreview
:TypstPreviewOpenBrowser
:TypstPreviewStop
```

For diagnostics and support:

```vim
:TypstDiagnostics
:TypstLocks
:TypstInfo!
:TypstLog
```

Use `:help typst-commands` for the full command reference, `:help
typst-start` for the minimal path, `:help typst-tinymist` for Tinymist
ownership, and `:help typst-preview-native` for native preview behavior.

Default output goes to `stdpath("cache")/typst.nvim/output/<main>.pdf`.
Set `output_dir = ""` to write next to the main Typst file, or set an explicit
relative or absolute path if you intentionally want project-local or external
artifacts.

The public Lua API is versioned: `api_version()` returns the current API level
and `version()` returns the same value in a table. Process-backed async result
tables expose `cancel()` and stop the originating process tree. If graceful and
forceful shutdown cannot prove the process exited, the operation first becomes
`orphaned-running`, then `orphaned-retained` after bounded stop attempts so
normal active-operation waits can continue. Cancellation callbacks receive that
unconfirmed stop result once. `on_finish()` callbacks, final cleanup, and lease
release still wait for a later real exit, which reports `was_orphaned = true`,
`exited_after_orphan = true`, and does not synthesize `stopped = true`. Reset
and clear-cache paths cancel background probes including Tinymist completion,
package info, font scans, and metadata version detection. Before 1.0, the
stable Lua API is intentionally narrow and symbol-based, not namespace-based.
Setup/contract introspection plus core `project`, `compiler`, and `viewer`
workflow helpers are stable when listed by `stable_symbols()`. Editing,
completion, artifact, metadata, provider, navigation, preview helper, and
development APIs remain installed but experimental unless promoted to the
stable-symbol block in `API.md`;
`experimental_symbols()` reports those helpers explicitly.
Use `contract()` to inspect the versioned API/event contract, including
documented `TypstEvent*` names and payload fields.

Project-scoped public Lua APIs use one no-project policy. Passive inspection
helpers such as `compiler.status()`, `compiler.current_output()`,
`viewer.preview_status()`, `project.services()`, and detailed reports reuse an
attached project, an explicit `project`, or an explicit project key (`key` or
`project_key`, with `key_encoded = true` for command-safe encoded keys); they
do not create scratch projects from dashboards, statuslines, timers, or other
non-Typst buffers, and they do not notify by default when no project exists.
Cleanup helpers such as `viewer.clean()` also use no-create resolution, but
remain action APIs. Action helpers such as compile, watch, preview, render,
export, eval, navigation, and semantic calls may resolve or create project
state only for Typst source buffers. From a non-Typst buffer they return
`no_project` instead of silently compiling an unintended main. Integrations
should pass `{ bufnr = typst_bufnr }`, `{ project = project }`, or an explicit
project key when the current buffer is not the Typst source. Viewer and preview
inverse-search helpers also resolve `opts.path` through loaded buffers or
existing project graphs before returning `source_path_not_in_project`.
`viewer.capabilities()` is project-free; preview capabilities are
project-scoped.

Default Typst buffer mappings:

| Mapping | Mode | Action |
| --- | --- | --- |
| `]]` | Normal/Operator/Visual | Next heading |
| `[[` | Normal/Operator/Visual | Previous heading |
| `][` / `[]` | Normal/Operator/Visual | Next/previous heading end |
| `]m` / `[m` | Normal/Operator/Visual | Next/previous structural block start |
| `]M` / `[M` | Normal/Operator/Visual | Next/previous structural block end |
| `]n` / `[n` | Normal/Operator/Visual | Next/previous equation start |
| `]N` / `[N` | Normal/Operator/Visual | Next/previous equation end |
| `]r` / `[r` | Normal/Operator/Visual | Next/previous raw block |
| `]/` / `[/` | Normal/Operator/Visual | Next/previous comment |
| `%` | Normal | Matching Typst delimiter, math fence, or raw fence |
| `gf` | Normal | Follow Typst target under cursor |
| `.` | Normal | Repeat last Typst structural edit or native change |
| `<localleader>ll` | Normal | Start or restart Typst watch |
| `<localleader>lL` | Normal | Run one-shot Typst compile |
| `<localleader>lk` | Normal | Stop current Typst compile/watch |
| `<localleader>lv` | Normal | View generated output |
| `<localleader>ls` | Normal | Forward-search viewer/preview |
| `<localleader>le` | Normal | Open compiler diagnostics |
| `<localleader>lo` | Normal | Open compiler output |
| `<localleader>li` | Normal | Show project info |
| `<localleader>lt` | Normal | Toggle project TOC |
| `<localleader>lc` | Normal | Clean Typst artifacts |
| `<localleader>lg` | Normal | Open typst.nvim log |
| `ih` / `ah` | Operator/Visual | Inner/outer heading |
| `iH` / `aH` | Operator/Visual | Inner/outer section |
| `im` / `am` | Operator/Visual | Inner/outer equation |
| `id` / `ad` | Operator/Visual | Inner/outer delimiter pair |
| `ic` / `ac` | Operator/Visual | Inner/outer content block |
| `ib` / `ab` | Operator/Visual | Inner/outer block |
| `ie` / `ae` | Operator/Visual | Inner/outer structural block |
| `iC` / `aC` | Operator/Visual | Inner/outer code block |
| `ir` / `ar` | Operator/Visual | Inner/outer raw block |
| `if` / `af` | Operator/Visual | Inner/outer function call |
| `ia` / `aa` | Operator/Visual | Inner/outer argument |
| `il` / `al` | Operator/Visual | Inner/outer label or reference |
| `ii` / `ai` | Operator/Visual | Inner/outer import statement |

Motion mappings are available in normal, operator-pending, and visual modes.
They accept Vim counts such as `2]m` and `3[[`.

Text objects are Tree-sitter-first. When a parser-backed text object cannot be
resolved and Tinymist supports `textDocument/selectionRange`, typst.nvim falls
back to the LSP selection range; inner text objects use the smallest returned
range, while outer text objects use the first parent range when one is
available. Lua callers can pass `lsp_fallback = false` to require parser-only
ranges. Counted outer argument text objects select consecutive arguments, such
as `y2aa`. Empty inner text objects and incomplete syntax return no range.
`ie`/`ae` are Typst structural-block objects, not TeX environments; they select
the nearest useful structural unit such as a function call, bracket/content
block, code/raw block, equation, grouped expression, array, dictionary, or list
item.

`gf` resolves imports, image/data/bibliography paths, local CSL style files,
package imports, URLs, labels/references, explicit `#cite(<key>)` citations,
and local/imported definitions. Built-in CSL style IDs such as `ieee` are not
treated as file paths. All defaults target `<Plug>(typst-...)` mappings and can
be disabled or overridden with `mappings`.

The `<localleader>l...` defaults intentionally mirror the common VimTeX command
workflow. In Typst, `<localleader>ll` maps to watch mode because that is the
closest equivalent to VimTeX's continuous compiler loop; one-shot compile is
available as `<localleader>lL`.

`<Plug>(typst-hover)` delegates to native LSP hover when a hover-capable Typst
language server is attached. It is not bound to `K` by default; set
`mappings.hover = "K"` or map the plug yourself if you want typst.nvim to own
that key.

Insert-mode `<Plug>` helpers are registered without default keys:
`<Plug>(typst-insert-strong)`, `<Plug>(typst-insert-emph)`,
`<Plug>(typst-insert-math)`, `<Plug>(typst-insert-content)`,
`<Plug>(typst-insert-code)`, and `<Plug>(typst-insert-raw)`. They insert paired
Typst markup and place the cursor inside. Bind them with `mappings.insert` or
your own `imap` calls.

Typst structural edits register repeat commands when they succeed. The default
`.` mapping replays the last Typst transform if no other buffer edit happened
since then; otherwise it falls back to Neovim's native dot-repeat. If
`repeat#set()` is available, typst.nvim also registers the same command with
that provider. Multi-token structural edits are undo-joined so one undo step
restores the full transform. Counted transform calls repeat through that same
undo chain, visual/command ranges are honored by range-capable transforms, and
structural edits do not clobber user registers.

Minimal setup:

```lua
require("typst").setup()
```

The runtime plugin calls `setup()` with defaults when Neovim sources
`plugin/typst.lua`. Later calls to `require("typst").setup({...})` are treated
as reconfiguration: one-time commands/autocmds stay installed, configuration is
validated again, and attached buffers are reapplied. Set
`vim.g.typst_nvim_no_auto_setup = 1` before plugin loading to opt out of the
default runtime setup and call `setup()` yourself.

Common setup snippets:

```lua
require("typst").setup({
  integrations = {
    tinymist = { lsp = "detect" },
  },
  diagnostics = {
    source = "fallback",
    use_quickfix = true,
  },
})
```

```lua
require("typst").setup({
  preview = {
    provider = "native",
    native = "browser",
  },
})
```

```lua
require("typst").setup({
  project = {
    index = {
      large_file_policy = "headings-only",
      max_file_bytes = 512 * 1024,
    },
  },
  completion = {
    path_scan_cache_ms = 1000,
    path_scan_entry_max = 500,
  },
})
```

`require("typst.config").snapshot()` returns an isolated copy of the active
configuration for integrations that only need to inspect settings.
`require("typst.config").get()` returns a read-only view for direct indexed
reads. Use `snapshot()` when you need to traverse or mutate a copy.
`unsafe_get()` is for typst.nvim internals that intentionally need the live
table.

The complete default-key reference and machine-readable schema are generated
from runtime defaults in `docs/config-reference.md` and
`data/config-schema.json`. Run `just config-docs` after changing defaults.

Example setup:

```lua
require("typst").setup({
  validation = "warn",
  metadata_version = nil,
  root_markers = { ".typstmain", "typst.toml", ".git" },
  main = nil,
  project = {
    import_scan = true,
    import_scan_max_files = 200,
    import_scan_max_depth = 3,
    import_scan_max_entries = 2000,
    import_scan_skip_dirs = {
      ".git",
      "node_modules",
      ".direnv",
      ".cache",
      "target",
      "build",
      "dist",
      "vendor",
      ".venv",
      "__pycache__",
    },
    persist_main = true,
    warn_on_low_confidence_main = true,
    index = {
      fs_watchers = "auto",
      max_file_bytes = 1024 * 1024,
      large_file_policy = "skip",
    },
  },
  output_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "typst.nvim", "output"),
  output_name = nil,
  compile = {
    provider = nil,
    extra_args = {},
    watch_output = "auto",
    watch_output_wait_ms = 1500,
    watch_structured_args = {},
    deps = true,
    open = false,
    typst_open = false,
    generic = {
      compile = nil,
      watch = nil,
      output = nil,
      cwd = nil,
    },
    task = {
      compile = nil,
      watch = nil,
      output = nil,
      cwd = nil,
    },
    fragments = {
      default = "markup",
      output_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "typst.nvim", "fragments"),
      -- Optional: force file-backed fragment wrappers for custom providers.
      -- Built-in Typst compiles selected fragments through stdin by default.
      source_dir = nil,
      templates = {
        markup = { prefix = "", suffix = "\n" },
        math = { prefix = "$ ", suffix = " $\n" },
        code = { prefix = "#{\n", suffix = "\n}\n" },
        document = { prefix = "", suffix = "\n" },
        auto = {
          prefix = "#set page(width: auto, height: auto, margin: 0pt)\n",
          suffix = "\n",
        },
      },
    },
    profiles = {
      draft = {
        output_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "typst.nvim", "draft"),
        output_name = "draft",
        output_format = "pdf",
      },
    },
  },
  integrations = {
    tinymist = {
      -- "auto" starts/reuses Tinymist through Neovim's built-in LSP client
      -- and skips startup when coc.nvim/coc-tinymist appears active.
      -- Use "detect" for passive existing-client queries, "off" to disable,
      -- or "start" to force nvim-lsp startup.
      lsp = "auto",
      client_names = { "tinymist" },
      path = "tinymist",
      -- Advanced: set cmd to override path with a full command prefix.
      cmd = nil,
      settings = {},
      init_options = {},
      capabilities = nil,
      on_attach = nil,
    },
  },
  diagnostics = {
    enabled = true,
    source = "fallback",
    use_quickfix = false,
    list = "quickfix",
    fonts = true,
    font_scan_timeout_ms = 250,
  },
  bibliography = {
    -- "auto" uses project-index citation completion only when native Tinymist
    -- and coc.nvim are unavailable or explicitly skipped.
    -- Use "project" to force fallback citation completion, "tinymist" to rely
    -- on native Tinymist, or "off" to disable project citation completion.
    completion = "auto",
    attachment_fields = { "pdf", "file", "attachment" },
    attachment_paths = {
      "{key}.pdf",
      "attachments/{key}.pdf",
      "pdf/{key}.pdf",
    },
  },
  format = {
    provider = "auto",
    command = "typstyle",
    extra_args = {},
    timeout_ms = 2000,
    prose_width = 80,
  },
  lint = {
    provider = "typst",
    command = nil,
    extra_args = {},
    timeout_ms = 2000,
  },
  grammar = {
    provider = "command",
    command = nil,
    extra_args = {},
    timeout_ms = 2000,
    stdin = nil,
    file_arg = nil,
  },
  viewer = {
    provider = "generic",
    open = nil,
    reload = nil,
    args = {},
    forward = nil,
    forward_args = {},
    inverse = nil,
    inverse_args = {},
  },
  preview = {
    provider = "native",
    native = "viewer",
    export = {
      mode = "compile",
      profile = nil,
      provider = nil,
      output_format = nil,
      output_name = nil,
      output_dir = nil,
      extra_args = {},
    },
    open = nil,
    stop = nil,
    refresh = nil,
    forward = nil,
    inverse = nil,
    reuse = true,
    capabilities = {
      forward = false,
      inverse = false,
      source_maps = false,
    },
    source_maps = {
      provider = nil,
      forward = nil,
      inverse = nil,
      capabilities = {
        forward = false,
        inverse = false,
        source_maps = false,
      },
    },
    fallback = "view",
    browser = {
      host = "127.0.0.1",
      port = 0,
      server = true,
      output_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "typst.nvim", "preview"),
      refresh_ms = 1000,
      open = nil,
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
  },
  syntax = {
    package_extensions = true,
    package_highlight_group = "TypstPackageSpecial",
    package_highlight_priority = 115,
    packages = {
      ["@preview/cetz"] = {
        highlight_group = "TypstPackageCetz",
        capture = "@typst.package.cetz",
        members = { "canvas", "draw", "line", "rect", "circle" },
      },
    },
  },
  conceal = {
    enabled = true,
    reveal = "node",
    reveal_insert = nil,
    reveal_by_category = {},
    conceallevel = 2,
    categories = {
      math_symbols = true,
      math_scripts = true,
      math_fonts = true,
      math_operators = true,
      math_wrappers = true,
      math_accents = false,
      math_delimiters = true,
      markup_delimiters = true,
      headings = false,
      lists = false,
      raw_blocks = false,
      raw_block_languages = false,
      labels = false,
      reference_markers = false,
      function_wrappers = {
        strong = true,
        emph = true,
        underline = true,
        strike = true,
      },
      emoji = false,
    },
    math = {
      scripts = {
        digits = true,
        signs = true,
        simple_letters = true,
        grouped = false,
        max_group_len = 4,
      },
      fonts = {
        enabled = true,
        styles = {
          cal = true,
          bb = true,
          frak = true,
          bold = true,
          sans = false,
          mono = false,
          italic = false,
        },
      },
      accents = {
        enabled = false,
        allow_combining = false,
        simple_ascii_only = true,
      },
    },
    renderer = {
      mode = "unicode",
      image = {
        enabled = false,
        max_inline_height = 8,
        debounce_ms = 250,
        cache = true,
        reveal = "node",
      },
    },
    custom = {
      math = {
        customop = "∗",
      },
    },
  },
  completion = {
    include_packages = true,
    include_templates = true,
    universe_index_paths = {},
    include_paths = true,
    include_csl_styles = true,
    csl_styles = {},
    include_raw_languages = true,
    raw_languages = {},
    include_colors = true,
    color_names = {},
    include_fonts = true,
    font_families = {},
    font_scan_timeout_ms = 250,
    path_scan_max = 200,
    path_scan_entry_max = 2000,
    path_scan_cache_ms = 300,
    csl_scan_max = 100,
    scan_cache_ttl_ms = 5000,
    package_scan_max = 500,
    package_cache_ttl_ms = 5000,
    package_cache_prewarm = false,
  },
  indent = {
    enabled = true,
  },
  structural_actions = {
    timeout_ms = 1000,
    patterns = {
      heading_promote = { "promote.*heading", "heading.*promote", "level.*up" },
      heading_demote = { "demote.*heading", "heading.*demote", "level.*down" },
      equation_toggle = { "toggle.*equation", "convert.*equation" },
      equation_inline = { "inline.*equation", "equation.*inline" },
      equation_block = { "block.*equation", "equation.*block" },
    },
  },
  folds = {
    enabled = true,
    foldlevel = 99,
  },
  toc = {
    mode = "window",
    position = "right",
    width = 32,
    height = 12,
    auto_close = false,
    follow_cursor = true,
    highlight_current = true,
    auto_refresh = true,
    follow_delay_ms = 40,
    refresh_delay_ms = 120,
    visible_layers = {
      heading = true,
      figure = true,
      table = true,
      equation = true,
      label = true,
      reference = true,
      citation = true,
      import = true,
      file = true,
      todo = true,
      definition = true,
    },
    mappings = {
      enabled = true,
      jump = "<CR>",
      preview = "p",
      close = "q",
      refresh = "r",
      toggle = "za",
      toggle_layer = "L",
      filter = "/",
      clear_filter = "\\",
    },
  },
  mappings = {
    enabled = true,
    next_heading = "]]",
    previous_heading = "[[",
    next_heading_end = "][",
    previous_heading_end = "[]",
    next_block = "]m",
    previous_block = "[m",
    next_block_end = "]M",
    previous_block_end = "[M",
    next_equation = "]n",
    previous_equation = "[n",
    next_equation_end = "]N",
    previous_equation_end = "[N",
    next_raw_block = "]r",
    previous_raw_block = "[r",
    next_comment = "]/",
    previous_comment = "[/",
    match = "%",
    follow = "gf",
    hover = false,
    repeat_transform = ".",
    commands = {
      watch = "<localleader>ll",
      compile = "<localleader>lL",
      stop = "<localleader>lk",
      view = "<localleader>lv",
      forward = "<localleader>ls",
      errors = "<localleader>le",
      output = "<localleader>lo",
      info = "<localleader>li",
      toc = "<localleader>lt",
      clean = "<localleader>lc",
      log = "<localleader>lg",
    },
    insert = {
      strong = false,
      emph = false,
      math = false,
      content = false,
      code = false,
      raw = false,
    },
    textobjects = {
      inner_heading = "ih",
      outer_heading = "ah",
      inner_section = "iH",
      outer_section = "aH",
      inner_equation = "im",
      outer_equation = "am",
      inner_delimiter = "id",
      outer_delimiter = "ad",
      inner_content = "ic",
      outer_content = "ac",
      inner_block = "ib",
      outer_block = "ab",
      inner_structural_block = "ie",
      outer_structural_block = "ae",
      inner_code_block = "iC",
      outer_code_block = "aC",
      inner_raw_block = "ir",
      outer_raw_block = "ar",
      inner_call = "if",
      outer_call = "af",
      inner_argument = "ia",
      outer_argument = "aa",
      inner_list_item = false,
      outer_list_item = false,
      inner_label = "il",
      outer_label = "al",
      inner_import = "ii",
      outer_import = "ai",
    },
  },
})
```

`project.import_scan_skip_dirs` entries are directory basenames, not paths or
glob patterns. Use `"build"` rather than `"build/"` or `"foo/build"`.

`:TypstPreview` uses `preview.open` when configured. Otherwise it uses the native
typst.nvim preview provider. The default native target is `preview.native =
"viewer"`, which opens the current compiler output through the configured PDF
viewer just like `:TypstView`. Set `preview.native = "browser"` to use
typst.nvim's local browser preview shell; it serves the selected preview output
from a loopback URL and refreshes active browser previews after compile/watch
cycles. The browser shell polls preview state every `preview.browser.refresh_ms`
milliseconds, which defaults to 250ms, and exposes lightweight reload, zoom,
fit, page, status/error, and source-sync controls.
Artifact responses larger than `preview.browser.max_artifact_bytes` return
`413 Payload Too Large`; under-cap artifacts are streamed in bounded chunks.
Setting the cap to `0` disables the size check for trusted local use.
When loopback binding is unavailable, typst.nvim opens a generated HTML shell
under `preview.browser.output_dir` instead. Set `preview.native = "auto"` to try
the browser shell first and fall back to the configured viewer.
The browser shell styling is configurable with `preview.browser.style`: set
`variables` to override CSS custom properties, `css` to append trusted inline
CSS, or `css_path` to load an absolute or project-relative stylesheet. Keep
shared styles under XDG config. For example:

```lua
require("typst").setup({
  preview = {
    browser = {
      style = {
        variables = {
          bg = "#111111",
          ["toolbar-bg"] = "#20242a",
          ["--my-preview-accent"] = "#ffcc00",
        },
        css = "#meta { font-variant-numeric: tabular-nums; }",
        css_path = vim.fs.joinpath(
          vim.fn.stdpath("config"),
          "typst.nvim",
          "preview.css"
        ),
      },
    },
  },
})
```

`preview.export.mode = "compile"` displays the artifact recorded by the compiler
service. `preview.export.mode = "profile"` runs a named `exports.profiles`
entry before display, and `preview.export.mode = "provider"` invokes an export
provider with a reserved output path. Preview exports are typst.nvim-owned and
are recorded with `producer = "preview"`; they do not replace the compiler
output path. Export providers receive `preview = true`, `preview_export = true`,
`preview_target`, and `update_compiler_output = false`. If no preview export
output directory is configured, typst.nvim writes into the preview cache with a
project-specific name. Browser refresh exports are generation-guarded so stale
exports cannot replace a newer active preview route.
`preview.browser.export.mode = "inherit"` makes the browser target use the
top-level preview export contract. `:TypstInfo` and `:TypstClean!` distinguish
document artifacts from preview-owned cache exports. Preview-owned artifact
records also retain their preview export target, mode, profile/provider, and
format so `:TypstArtifacts`, `:TypstInfo`, and health can report preview cache
exports separately from document exports.
`preview.cache.max_entries`, `preview.cache.max_bytes`, and
`preview.cache.ttl_ms` prune stale preview-owned cache exports after preview
profile/provider exports. Active browser output is preserved. Use
`:TypstCleanPreview[!] [format]` for explicit preview-cache cleanup; bang
forces deletion of changed-but-owned preview artifacts while still preserving
the active preview output.

Native browser and external viewer validation is tracked in
`docs/preview-viewer-matrix.md`. Use `just preview-matrix browser-server` to
exercise the default URL opener, or use a named browser/PDF target such as
`safari`, `chrome`, `skim`, `sioyek`, `zathura`, `okular`, or `evince` when that
application is installed and you want an app-specific check.

Browser opener failures are reported as preview state instead of disappearing:
`:TypstPreviewStatus!` shows the attempted URL, opener candidates, transport,
shell path, and last error. By default, leave `preview.browser.app = nil` and
`preview.browser.commands = nil`; typst.nvim opens the URL through
`vim.ui.open()` when available, then the OS default URL opener such as `open`,
`xdg-open`, or Windows shell openers. Set `preview.browser.app = "firefox"`,
`"chrome"`, `"safari"`, `"edge"`, `"brave"`, or another app/executable name
only when you want a specific browser. The URL is also available as
`g:typst_nvim_last_preview_url` so it can be copied with
`:let @+ = g:typst_nvim_last_preview_url`. For SSH, WSL, containers, or remote
Neovim sessions, prefer keeping the server on loopback and configure explicit
opener commands. Binding to a reachable interface requires
`preview.browser.allow_remote = true`; only enable it on trusted networks.
Remote browser routes include a token by default through
`preview.browser.token = "auto"`, or you can set a fixed non-empty token.

```lua
require("typst").setup({
  preview = {
    native = "browser",
    browser = {
      host = "127.0.0.1",
      -- Set allow_remote = true only with a non-loopback host on trusted networks.
      -- token = "auto" protects remote routes with a per-route token.
      -- Optional local browser picker:
      -- app = "chrome",
      -- Lower-level opener override for remote environments:
      commands = {
        { "wslview", "{url}" },
      },
    },
  },
})
```

`preview.browser.performance = "safari"` opts into a conservative fallback for
Safari-style reload lag: file-shell transport, slower polling, and a reload
throttle. `preview.browser.reload_throttle_ms` can be used directly for any
browser that struggles with frequent watch refreshes. For fast browser preview,
prefer SVG output and a preview export profile that avoids heavyweight document
features:

```lua
require("typst").setup({
  exports = {
    profiles = {
      preview_svg = {
        output_format = "svg",
        extra_args = {
          "--pages", "1",
          "--input", "preview=true",
        },
      },
    },
  },
  preview = {
    native = "browser",
    browser = {
      performance = "fast",
      reload_throttle_ms = 150,
      export = {
        mode = "profile",
        profile = "preview_svg",
      },
    },
  },
})
```

Native typst.nvim preview only:

```lua
require("typst").setup({
  preview = {
    provider = "native",
    native = "browser",
    follow_buffer = true,
    source_maps = {
      provider = "typst-query",
    },
    browser = {
      performance = "fast",
      export = {
        mode = "profile",
        profile = "preview_svg",
      },
    },
  },
})
```

typst-preview.nvim for live preview, typst.nvim for project workflow:

```lua
require("typst").setup({
  preview = {
    provider = "typst-preview.nvim",
    native = "viewer",
  },
})
```

In that hybrid setup, use typst-preview.nvim for its live/incremental browser
frontend and keep typst.nvim for root/main ownership, compile/watch/view,
export profiles, bibliography, navigation, health, logs, and cleanup. Tinymist
or coc-tinymist still owns semantic LSP features.

`:TypstPreviewOpenBrowser[!]` opens the native browser target regardless of the
default `preview.native`; bang restarts an active preview. `:TypstPreviewReload`
refreshes an active preview, and `:TypstPreviewStatus[!]` shows backend,
transport, output, export, and cache state. `:TypstPreview` and
`:TypstPreviewOpenBrowser` accept `mode=...`, `profile=...`, `format=...`,
`export=...`, and `restart` tokens for one-shot preview export overrides.

`:TypstPreviewStop` uses `preview.stop` when configured, and otherwise stops the
tracked native browser session when one is active. `:TypstPreviewToggle` toggles
the tracked preview state. Repeated `:TypstPreview` calls reuse the active
project preview by default; pass `restart = true` to
`require("typst").viewer.preview()` or set `preview.reuse = false` to stop and
reopen active previews instead. Set `preview.follow_buffer = true` to make one
active native browser preview follow the focused Typst buffer's resolved
project/main without opening a new browser tab. `preview.forward`,
`preview.inverse`, and `preview.capabilities` remain supported for optional
source-map support; new integrations should prefer
`preview.source_maps.provider`, `forward`, `inverse`, and `capabilities`. The
default `preview.source_maps.provider = "typst-query"` can source-sync SVG
browser previews by querying Typst block positions and matching them to local
source text. It does not claim SyncTeX-style support for normal Typst PDFs and
does not replace Tinymist semantic features. Use
`preview.provider = "typst-preview.nvim"` only when you explicitly want
compatibility delegation to that plugin. In that mode,
`:TypstViewForward` may call
`:TypstPreviewSyncCursor` for the galley preview workflow when the external
browser preview source-map command is available.

Registered source-map integrations use the `source_map` provider kind. A
provider may implement `forward`, `inverse`, `generate`, `resolve`, or
`browser_inverse`. Native browser server mode sends DOM/SVG click coordinates
to `browser_inverse` through its local `/source-sync` route and opens the source
location returned by the provider. PDF plugin clicks and file-shell fallback
tabs cannot be intercepted by typst.nvim.

Rendered previews are explicit actions, not automatic inline rendering on every
edit. `:TypstPreviewFragment` renders the selected source, `:TypstPreviewEquation`
renders an equation expression or selection, `:TypstPreviewImage [path]`
previews an image path under the cursor, and `:TypstPreviewPage [page]` renders
one document page. Outputs are cached under `render.output_dir`, keyed by
source, project context, format, page, and executable. Equation and fragment
previews default to `render.source_mode = "stdin"`, pass source to
`typst compile -`, and do not write generated wrapper sources. Set
`render.source_mode = "file"` when a renderer/provider needs a real source
file; typst.nvim writes it under `render.source_dir` and removes unremembered
source/output files after success, stale completion, cancellation, or failure.
Rendered artifacts live under the XDG-backed `render.output_dir`.
`:TypstRenderCacheClear`
clears manifest-owned render cache entries, while `:TypstRenderCacheClear!`
forcibly removes the configured render cache directory only when typst.nvim can
prove ownership: the path must be under the default render cache root or contain
typst.nvim's render-cache sentinel. If `render.output_dir` points at a project
directory, an unmarked shared asset directory, or the project root, forced clear
returns `unsafe_cache_dir` and preserves the directory. The default renderer
uses `typst compile` to SVG or PNG and opens a scratch buffer with the rendered
artifact path, SVG dimensions when available, and cache metadata. Set
`render.display_provider` or pass
`display_provider` as `"terminal"`, `"kitty"`, `"wezterm"`, or `"iterm"` for
built-in in-buffer terminal image display for Kitty, WezTerm, and iTerm-style
protocols. Kitty uses its graphics file-transfer protocol, so rendered image
bytes are transferred by path. iTerm/WezTerm inline display is bounded by
`render.max_inline_image_bytes` and uses typst.nvim's built-in Lua base64
encoder; if inline display fails, typst.nvim falls back to the scratch-buffer
report. Custom render providers can still
implement `display(result, opts)` or `render(project, opts, callback)`.

Statusline integrations can use:

```lua
require("typst").ui.status()
require("typst").ui.status({ telemetry = true })
require("typst").ui.statusline()
```

`status()` includes the last active compile profile, and `statusline()` displays
it by default when present. `status()` also exposes root/main decision sources,
last command/cwd, active process or watcher PID, project-specific Tinymist
Neovim LSP visibility, effective compiler diagnostics policy, and viewer/preview backend
details for statusline and dashboard integrations. It also exposes watcher
cycle state when continuous compilation is active. It includes Typst-aware
current-buffer word and character counts plus project index cache hit/miss
statistics; `statusline({ words = true })` appends the word count. The status
string is read through the active compiler provider's `status(project)` method.
Pass `{ telemetry = true }` to include the same performance telemetry summary
reported by `:TypstTelemetry`.
`:TypstStatus` echoes the compact current-project status, and `:TypstStatus!`
echoes the compact table for every registered Typst project. `:TypstStatusAll`
does the same explicitly, and `:TypstStatusAll!` opens the all-project report in
a scratch buffer. Use `:TypstInfo` or `:TypstInfo!` for the detailed
current-project report.

`:TypstCount` counts visible Typst words and characters in the current buffer;
a range counts selected lines, and `:TypstCount!` aggregates all readable files
known to the current Typst project.

`:TypstFormat` formats the current buffer through Tinymist when available, then
falls back to `typstyle` in stdin/stdout mode. `format.provider` can also be a
registered provider name, callback, or provider table for custom formatters.
Set `format.provider = "prose"` to wrap plain Typst prose paragraphs while
leaving headings, code, math, raw blocks, lists, and function/code lines
unchanged. `format.prose_width` controls the wrap width.

`:TypstLint` runs the configured lint provider. The default provider invokes
`typst compile` against a temporary output and publishes parsed Typst human or
short diagnostics through `vim.diagnostic`. `:TypstLint!` also opens the
quickfix list for the lint result.

`:TypstGrammar` runs the configured external prose or grammar checker and
publishes parsed diagnostics through `vim.diagnostic`. `grammar.provider` may
be `"command"`, `"textidote"`, `"vlty"`, a registered provider name, callback,
or a provider table. Generic command providers default to stdin; `textidote`
and `vlty` default to passing the current file path. textidote line/column
output and Vale/vlty-style JSON output are normalized to Typst diagnostics.
`:TypstGrammar!` opens quickfix for the result.

`:TypstFontDiagnostics` checks `font:` family references in the current buffer
against configured `completion.font_families` and families reported by
`typst fonts`. `diagnostics.font_scan_timeout_ms = 0` skips the CLI scan.
`:TypstFontDiagnostics!` opens quickfix for missing families.

Compiler diagnostics can use either the global quickfix list or the current
window's location list. Keep `diagnostics.list = "quickfix"` for the default
behavior, or set `diagnostics.list = "loclist"` when `:TypstDiagnostics` and
automatic `diagnostics.use_quickfix` publishing should stay window-local.

Plugin integrations can register named Lua providers with
`require("typst").providers.register(kind, name, provider)`. Supported kinds are
`compiler`, `format`, `lint`, `grammar`, `viewer`, `picker`, `toc`, `index`,
`export`, `eval`, `init`, `profile`, `test`, `bench`, `coverage`, `semantic`,
and `render`, with aliases such as `compile`, `formatter`, `linter`, `view`,
`exports`, `template`, `benchmark`, and `terminal_image`. Registered names are
valid string values in the matching config field, for example
`compile.provider = "my-compiler"` or `format.provider = "my-format"`.
`providers.names(kind)`, `providers.get(kind, name)`, and
`providers.unregister(kind, name)` expose the registry for extension plugins.
Provider return, callback, timeout, and cancellation rules are documented in
[`docs/provider-contracts.md`](docs/provider-contracts.md).

`:TypstCompile [profile]`, `:TypstCompileSS [profile]`, and
`:TypstWatch [profile]` apply named compile
profiles from `compile.profiles`. A profile can override `output_dir`,
`output_name`, `output_format`, `extra_args`, `watch_output`,
`watch_output_wait_ms`, `watch_structured_args`, `deps`, `open`, and
`typst_open` for that run.
Unsupported profile keys fail validation instead of being silently ignored.
`open = true` opens the successful output through typst.nvim's configured
viewer; `typst_open = true` passes Typst's raw `--open` flag instead.
With `deps = false`, the run preserves the existing dependency graph.
Watch mode tracks each Typst compile cycle separately: cycle start/success/
failure events are emitted, stale diagnostics are replaced per cycle, and
`:TypstInfo` reports whether the watcher is currently compiling plus the last
cycle result. Each cycle also gets a monotonic `cycle_generation` that keeps
increasing across watcher restarts. If the watch process exits after parsed
cycles, typst.nvim keeps the last cycle as the build result instead of
synthesizing another compile success or failure from the process exit. Typst's
default watch output is human-readable, and Typst CLI 0.15 does not expose a
stable structured watch-status flag, so typst.nvim treats that parser as a
fixture-gated best-effort compatibility layer. If a future or wrapper Typst
binary can emit stable JSON-line watch events, configure
`compile.watch_structured_args` for those flags; set
`compile.watch_output = "structured"` to fail closed when human-readable status
lines appear. Retained watcher stdout/stderr are bounded, and unterminated
partial-line buffers are bounded too so long-running watch processes cannot
grow memory unboundedly. Repeated watch restarts are debounced while the old
watcher is stopping, so typst.nvim sends one termination request and starts one
replacement watcher. After a successful watch cycle, typst.nvim waits up to
`compile.watch_output_wait_ms` for the expected output file to become readable
before treating the cycle as a missing-output failure. Set it to `0` to disable
the wait; values above 60000 ms are rejected as configuration errors. Completed
watch cycles notify optional
`viewer.reload(project, result, opts)` and `preview.refresh(project, result,
opts)` callbacks with `opts.source == "watch"` and `opts.watch == true`.
One-shot compile success notifies the same callbacks with
`opts.source == "compile"`. `:TypstCompile!` and `:TypstWatch!` request
typst.nvim-managed viewer opening after a successful build; watch opens on the
first successful cycle and then continues to notify reload/refresh callbacks.
`executable` may be a string such as `"typst"` or a list prefix such as
`{ "uv", "run", "typst" }`; typst.nvim appends the Typst subcommand and
arguments without going through a shell.

`output_name` controls the generated output filename. It must be a basename; use
`output_dir` for directories. If it has no extension, typst.nvim appends
`output_format`.

`:TypstCompileSelected [template]` compiles the selected line range as a
generated fragment without changing the registered project state. Templates are
read from `compile.fragments.templates`; the defaults are `markup`, `math`,
`code`, `full-page`, and `auto-sized`, with `document` and `auto` kept as
aliases. Fragment outputs are written to `compile.fragments.output_dir`, which
defaults to `stdpath("cache")/typst.nvim/fragments`. Generated fragment source is
passed through stdin by default: the built-in Typst provider runs
`typst compile -`, generic/task providers receive stdin and `{main}` expands to
`-`, and custom provider callbacks can read the internal runtime field
`run_config.compile.stdin`. `compile.stdin` is not a public setup option.
Generic/task `{source}` still expands to the originating source path when it is
known, and `{stdin}` expands to `1` for stdin-backed fragment compiles.
Project-relative imports still resolve with the project `--root`, without
writing wrapper files into the project. Set `compile.fragments.source_dir` or a
template `source_dir` only when a compiler provider needs a real temporary
source file; file-backed sources are cleaned up after the fragment compile
resolves or if the provider fails to start. Output artifacts remain available.

`validation = "warn"` records and logs unknown setup keys so typos such as
`diagnostic.source` do not silently disappear into the merged config. Use
`"strict"` to error on unknown keys, or `"off"`/`false` to disable the warning.

Main-file resolution checks `vim.b.typst_main`, saved explicit `:TypstSetMain`
choices, a leading `// typst.nvim: main = ../main.typ` directive, configured
`main` values, a nearest `.typstmain` project file, existing dependency graphs, capped
`#include`/`#import` scanning, nested-file `main.typ` heuristics, and finally the
current buffer. `main` may be a string, callback, or table keyed by project root. Table
values may be strings or callbacks, allowing per-root main-file mappings.
Relative table keys are normalized once during `setup()` against the setup-time
cwd; later `:cd` or `:lcd` changes do not change those mappings. When `root` is
not configured, table keys also act as root hints, so subprojects inside a
larger Git repository can resolve before the `.git` marker is used. A
throwing `root` or `main` callback is caught, logged, and treated as no match so
the remaining resolvers can continue; typst.nvim does not leave a half-attached
buffer because a user resolver failed. A
`.typstmain` file contains the main path relative to the file's directory,
either as a bare path or `main = path`. `:TypstToggleMain` switches the current
buffer between local-main mode and the resolved project main. Set
`project.persist_main = false` to disable saved `:TypstSetMain` choices.
When a buffer is renamed with `:saveas`, its saved explicit-main choice follows
the new buffer path.
`:TypstSetMain` rejects unreadable targets before writing buffer or persisted
state. Use `:TypstSetMain!` or Lua `set_main(..., { force = true })` only for a
not-yet-created main that another tool will create during this session, or for a
path that will be readable before the next resolution relies on persisted state.
If a later resolution sees an unreadable saved explicit main, typst.nvim treats
it as stale and clears the saved entry.
Unreadable explicit main paths are ignored during resolution; stale
`vim.b.typst_main` values are cleared so import scanning and current-buffer
fallbacks can recover after a main file is deleted or moved. Root-level files in
the same repository are allowed to resolve as independent mains rather than all
falling back to a sibling `main.typ`.
Project state records `dependency_sources` and `file_sources` values of
`explicit`, `compiler`, or `heuristic`; existing graph attachment uses that
priority order so heuristic associations do not override explicit or
compiler-discovered project membership.
Project resolution also records a main-file confidence label. Explicit sources
are high confidence, import-scan matches are medium confidence, and fallback
guesses such as current-buffer or nested `main.typ` are low confidence.
Existing-project graph matches inherit the matched project's original main
confidence; when no prior confidence is available they are treated as medium.
Compile/watch warn once per project before using the nested `main.typ`
heuristic unless `project.warn_on_low_confidence_main = false`. Other
low-confidence fallbacks are reported in `:TypstInfo!` but do not warn today.
When attach reaches the bounded import-scan fallback, it first attaches with
the later heuristic and records `resolution_pending = "import_scan"`; a
scheduled scan reassigns the buffer if it finds a unique importing main.
Unnamed Typst buffers attach to a scratch in-memory project rooted at the
current working directory; `:saveas` re-resolves them as normal file-backed
projects and prunes the scratch project. Scratch project main paths are
internal identity keys, not readable Typst files. Normal `:TypstCompile`,
`:TypstWatch`, and native preview compile-mode reject unnamed buffers with an
actionable "save first" error. Stdin-backed fragment workflows such as
`:TypstCompileSelected` are intentionally allowed from unnamed buffers because
they send generated source to `typst compile -` instead of compiling the
synthetic scratch path.

The shipped Tree-sitter highlight query covers Typst markup, code, math,
comments, raw blocks, and punctuation, and also marks TODO/NOTE/WARN/FIXME
comments plus parser `ERROR` nodes with dedicated captures. The broad
`tests/fixtures/basic/syntax.typ` fixture keeps those captures parser-backed.
Spell checking is query-driven too: prose and comments use `@spell`, while raw
spans/blocks, strings, and math regions use `@nospell`.
The highlight query also adds Tree-sitter `bo.commentstring` metadata so
Neovim's built-in commenting can prefer `// %s` inside line comments and
`/* %s */` inside block comments.
typst.nvim also ships a conservative Vim `syntax/typst.vim` fallback for users
without a Typst Tree-sitter parser. It covers common comments, headings,
markup, raw blocks, labels/references, `#` code, strings, numbers, and math, but
Tree-sitter remains the source of truth for rich highlighting, injections,
folds, indentation, text objects, and conceal.
The query suite also includes Markdown host injections for fenced
```` ```typst ```` blocks so embedded Typst snippets get Typst highlighting
when a Markdown parser is available.

Conceal uses versioned Typst metadata snapshots generated from Typst's Rust
library. Set `metadata_version = "0.14.2"` or `"0.15.0"` to pin a bundled
snapshot, or leave it `nil` to use the newest compatible bundled metadata. Tree-sitter finds candidate math identifiers, dotted fields, delimiters,
scripts, math calls, shorthand operators, heading markers, list markers, raw
fences, labels, and shorthand reference markers. Lua first checks custom math mappings from
`conceal.custom.math` and `require("typst").conceal.register("math", name,
replacement)`, then uses cached lookup maps generated from the active metadata
snapshot. Explicit
`emoji.*` names use a separate generated metadata table and are concealed only
when `conceal.categories.emoji = true`; the default single-cell width safety
usually keeps emoji glyphs visible as source unless you opt into wider
replacements. Structural punctuation remains syntax-driven, and ephemeral
extmarks are only applied for empty replacements or exactly one character that
passes the configured width safety. Resolved matches are cached per buffer,
changedtick, conceal generation, and conceal config; rendered viewport matches
are cached per window so cursor movement can reapply reveal policy without
recollecting Tree-sitter matches. Shadowing analysis is cached separately. With
`conceal.reveal = "node"`, reveal is window-local: each split leaves only the
candidate under that window's cursor as source text. `conceal.reveal = "line"`
reveals the cursor line, `conceal.reveal_insert` can override reveal behavior in
Insert mode, and `conceal.reveal_by_category` can override individual
categories.
This deliberately does not use Tree-sitter highlight-query `conceal` metadata:
typst.nvim needs category toggles, metadata safety checks, shadowing checks, and
window-local reveal behavior that native highlight conceal cannot express.
`:TypstConcealInspect` explains the rule under the cursor, including source
text, replacement, resolved symbol, metadata version when applicable, category,
range, and shadowing decision.
Implicit symbol conceal is suppressed when a local `#let`, function parameter,
explicit import binding, import alias, or wildcard import makes the built-in
meaning uncertain; this is a Tree-sitter lexical approximation that considers
declaration order and block/content scopes, not semantic resolution. Explicit
`sym.*` symbols still allow custom or built-in symbol resolution. The
implemented categories are `math_symbols`, `math_scripts`, `math_fonts`,
`math_operators`, `math_wrappers`, `math_delimiters`, `markup_delimiters`,
style `function_wrappers`, opt-in `headings`, opt-in `lists`, `raw_blocks`,
`raw_block_languages`, opt-in `labels`, `reference_markers`, and opt-in
`emoji`. Unicode conceal is the default renderer. `conceal.renderer.mode =
"image"` is an experimental opt-in placeholder for future equation image
conceal that will reuse typst.nvim's render/artifact cache.

Package-aware syntax extensions run after project attach and use the project
index to find exact Typst package imports. The default configuration recognizes
`@preview/cetz` and highlights imported CeTZ entry points such as `#canvas`
with `TypstPackageCetz`; users can add more package specs under
`syntax.packages`. `require("typst").syntax.package_extensions()` lists active
package specs, `package_matches()` returns the resolved ranges, and
`refresh()` reapplies the extmark-backed highlights. This keeps package
special-casing in Lua metadata instead of dynamically rewriting the core
Tree-sitter highlight query.

Tinymist remains responsible for semantic hover, definitions, function
documentation, and package-member language information. typst.nvim provides
package resource inspection and symbol information instead of a fake `texdoc`
equivalent. `:TypstPackageInfo [query]` parses exact `@namespace/name:version`
imports, locates Typst's reported package cache paths, renders cached manifests
and README files, exposes entrypoint/manual/API paths plus optional
typst.nvim-specific `[tool.typst-docs]` resource hints, and falls back to Typst
Universe when the package is not cached. Imported package members such as
`#canvas`, `#cetz.canvas`, nested items, module-value reimports, and
single-package wildcard imports resolve back to the exact cached package version
and its `///` source comments when available; those comments are syntactic
fallbacks, not semantic documentation. `:TypstPackageReadme`,
`:TypstPackageSource`, and `:TypstPackageOpen` open the cached README, cached
source entrypoint, and Universe page.

`:TypstSymbolInfo [query]` shows generated symbol or emoji metadata: glyph,
qualified form, metadata version, category, and variants.
`:TypstSymbolVariants [query]` lists generated variants. These commands report
symbol information, not Typst standard-library function documentation. Lua
consumers can read compact generated stdlib data through
`require("typst").metadata.stdlib_item(path)`, `metadata.signature(path)`, and
`metadata.stdlib_complete(prefix, context)`.

`:TypstContextMenu` builds a cursor-sensitive action list from package,
symbol, and follow resolvers. It can show package info, open package
source/online pages,
update package imports to newer locally cached versions, open, reveal, or jump
to resolved targets, and copy the resolved target. Function calls can show
signatures. Symbols offer a generated-variant insertion action; template
packages can open package info/source or initialize a project; file paths can be
revealed, image paths can be opened or previewed, and colors and font families
can be inspected or replaced. Labels can be copied, renamed, or listed through
quickfix references; syntactic label rename validates the current source token
before applying fallback edits and reports `provider = "syntax"` with
`semantic = false`. Tinymist-backed rename reports `provider = "tinymist"`.
Local definitions can list Tinymist semantic references when available, then
fall back to project occurrences. Headings can be promoted or demoted, and
equations can be converted between inline/block syntax or wrapped with
numbering. Citation targets also offer bibliography-entry, formatted-preview,
rename, URL, DOI, and readable attached-PDF actions. Attached PDFs are resolved
from configured bibliography fields and path patterns.

The project index is persistent per project and caches each scanned Typst or
bibliography file by loaded-buffer `changedtick` or on-disk mtime/size plus the
active index policy. `project.index.max_file_bytes` limits unloaded-file static
indexing. `project.index.large_file_policy = "skip"` omits oversized unloaded
files, `"headings-only"` reads the file to recover headings and local
imports/includes while skipping heavier symbol/reference scans, and `"scan"`
fully scans oversized files. Unnamed Typst buffers use their scratch project
main path as the index key and are rescanned by buffer changedtick, so fallback
headings, labels, references, definitions, and TODOs work before the buffer has
a file name.
Bibliography parsing handles multiline/concatenated BibTeX fields and nested
or inline Hayagriva YAML fields for citation metadata. Public bibliography
helpers expose expanded BibTeX `crossref`/`xdata` fields, formatted citation
previews, configurable attachment discovery, transactional citation-key rename,
and project bibliography status summaries.
`bibliography.completion = "auto"` uses project-index citation completion when
no Tinymist owner is visible, or when explicitly skipped with
`include_tinymist = false`, but avoids adding project citation candidates when a
native Neovim Tinymist client is attached or coc.nvim appears active.
`project`, `tinymist`, and `off` select project-only, Tinymist/Coc-owned, or no
project citation completion respectively.
`:TypstBibliographyDiagnostics[!]` reports explicit undefined citations,
duplicate bibliography keys, unused bibliography entries, and label/citation
name collisions through a dedicated diagnostic namespace; bang opens quickfix.
`require("typst").bibliography.foldexpr()` and
`require("typst").bibliography.indentexpr()` provide
conservative BibTeX and Hayagriva helpers for integrations that attach
bibliography buffers.
Headings, labels, citations, TOC layers, follow targets, package syntax
extensions, completion, picker items, and context actions consume the same
cached syntactic data instead of independently rescanning every known file on
each request. The project index supports local `#include` `.typ` traversal and
local `#import` traversal so fallback labels, headings, definitions, and TODOs
work before a compiler dependency graph is available.
Lua callers that need semantic index data can pass
`include_tinymist = true` to `typst.index.collect(...)`; this overlays
Tinymist document/workspace symbols and their references onto returned
headings, definitions, and references without changing the default syntactic
cache used by completion. Semantic collection is cache-first and nonblocking:
the immediate result is the syntactic index plus any currently valid Tinymist
cache, and missing or stale semantic data is refreshed asynchronously.
index providers extend the syntactic project index. Extension plugins can
register `index` providers whose `collect(project, opts)`
method returns normal index categories or `items` with `kind`, `name`, and
source location fields. Provider registration or unregistration invalidates the
aggregate index cache; `typst.index.mark_dirty(project, reason)` is available
for provider-specific refreshes.

Completion asks attached Tinymist clients for `textDocument/completion` first in
semantic Typst contexts, then falls back to project and metadata sources when
Tinymist is unavailable or returns no matches. Lua callers can pass
`include_tinymist = false` to use only the syntactic fallback. Fallback
completion combines local definitions, direct and wildcard file imports,
simple file re-exports, module-alias members from the project index, generated stdlib
function/element/type and member metadata, generated symbol/emoji metadata,
cached package roots, optional Universe index JSON, and CSL bibliography styles.
Package and template completions are offline: typing an `@namespace/name`
prefix suggests exact cached specs such as `@preview/cetz:0.3.4`, labels
template packages separately, and includes manifest descriptions, entrypoints,
compiler constraints, and template metadata when present. Set
`completion.universe_index_paths` to local JSON index files to add package and
template specs that are not installed in the Typst cache. Inside path strings
for `#import`, `#include`, `image`, `bibliography`, `read`, and raw/data-style
calls, it scans the current directory level and returns matching filesystem
entries with context-sensitive extension filters. Inside
`bibliography(..., style: "...")` and `cite(..., style: "...")`, it suggests
built-in Typst CSL style IDs, configured `completion.csl_styles`, and
project-local `.csl` files. Project-index glossary entries complete from
conservative `#let` glossary/acronym/term data, including dictionary-style
entry keys and `key: "..."` fields; external consumers can read them through
`typst.index.glossary_entries(project)`. Referenced files, including local CSL
style files, are available through `typst.index.paths(project)`.
Named-parameter and signature fallback uses generated stdlib signatures plus
simple local/imported `#let function(...)` signatures from the project index.
In `#set` rules, generated stdlib parameters are filtered to fields Typst marks
as settable. Parameter completion loads generated native parameter
documentation lazily for menu details.
`:TypstNameArguments` uses local signatures first and then generated stdlib
signatures only when Typst marks the relevant positional parameters as
nameable.
Parameter-value fallback uses generated
CastInfo constants for accepted values such as `image(fit: "cover")` or
`text(style: "italic")`, and expands generated stdlib constants for accepted
value types such as `text(dir: rtl)` and `align(alignment: center)`. Accepted
value completions include Typst's generated value-specific documentation when
the stdlib exposes it. Compact generated MessagePack metadata is bundled for
built-in functions, elements, types, parameters, returns, members, shorthands,
constants, categories, parameter details, and deprecations, without bundling a
package-documentation system.
In raw block fences such as
```` ```py ````, it suggests common language IDs, configured
`completion.raw_languages`, and installed Tree-sitter parser names. In
color-like arguments such as `fill:` and `stroke:`, it suggests generated
Typst stdlib color constants, configured `completion.color_names`, and
generated `color.map.*` presets. In `font:` arguments, it suggests configured
`completion.font_families`, families discovered by `typst fonts`, and a small
embedded fallback set when the CLI scan is unavailable.
Disable package scanning with `completion.include_packages = false`, disable
filesystem path completion with `completion.include_paths = false`, disable CSL
style completion with `completion.include_csl_styles = false`, disable raw
language completion with `completion.include_raw_languages = false`, disable
color completion with `completion.include_colors = false`, disable font
completion with `completion.include_fonts = false`, or cap scans with
`completion.package_scan_max`, `completion.path_scan_entry_max`,
`completion.path_scan_max`, `completion.csl_scan_max`, and
`completion.font_scan_timeout_ms`. `completion.path_scan_entry_max` caps raw
directory iterator consumption, while `completion.path_scan_max` caps returned
path items. Filesystem path directory entries are cached briefly with
`completion.path_scan_cache_ms`; set it to `0` to disable that cache.
Raw-language parser discovery and project-local CSL file scans are cached by
config generation and expire after `completion.scan_cache_ttl_ms`; set it to
`0` to keep those scan snapshots until config changes or `:TypstClearCache`.
Completion frontends can consume the same service through
`require("typst").completion.native(opts)`,
`require("typst").completion.cmp(opts)`,
`require("typst").completion.blink(opts)`,
`require("typst").completion.cmp_source(opts)`, and
`require("typst").completion.blink_source(opts)`.

`:TypstPick [kind]` exposes the same project/TOC model through picker backends.
`picker.provider = "auto"` tries Telescope, fzf-lua, fzf.vim, Snacks, then
`vim.ui.select`; it may also be `"fzf_vim"` or a registered provider name. Use
`require("typst").picker.items()` for custom consumers that want normalized
labels, citations, bibliography entries, imports, paths, TODOs, definitions, and TOC entries without
opening UI. Use `:TypstPick toc` to pick directly from the TOC model, including
custom TOC provider layers. Registered TOC layer names may also be used
directly, for example `:TypstPick theorem` for a provider that emits
`layer = "theorem"`.
Use `:TypstPick bibliography` for insertion-ready bibliography entries. Items
include `citation_key`, `fields`, and `insert_text`; `citation_form =
"function"` returns `#cite(<key>)`, `citation_form = "label"` returns `<key>`,
and the default returns `@key`.
`:TypstToc` opens a dedicated project TOC buffer by default. It merges
heading/document-symbol entries with index layers for figures, tables,
equations, labels, references, citations, imports, file paths, TODO comments,
and local definitions. Set `toc.mode = "quickfix"` or pass
`{ mode = "quickfix" }` to the Lua API to use quickfix as the presentation.
Extensions can add custom TOC layers by registering a `toc` provider with a
`collect(project, opts)` function that returns entries with `title`, `layer`,
and source location fields.
TOC buffers install configurable buffer-local mappings through `toc.mappings`
for `jump`, `preview`, `close`, and `refresh`: `jump` opens the selected item,
`preview` opens it in the source window while keeping focus in the TOC, `close`
closes the TOC window or quickfix list, and `refresh` rebuilds the current
project outline. In the dedicated TOC buffer, `toggle` expands or collapses the
current heading and `toggle_layer` hides or shows the current entry's layer for
that project. When `toc.follow_cursor` and
`toc.highlight_current` are enabled, moving through an attached Typst source
buffer moves and highlights the visible TOC entry for the current section.
Cursor-follow updates are debounced by `toc.follow_delay_ms`.
`filter` prompts for a case-insensitive TOC filter across titles, layers, and
paths; `clear_filter` restores the full view.
Manual and automatic TOC refreshes preserve the TOC cursor entry, collapsed headings,
filters, and per-project layer visibility.
When `toc.auto_refresh` is enabled, edits and writes in attached Typst buffers
debounce a refresh of the open TOC without moving focus from the source window;
`toc.refresh_delay_ms` controls that debounce delay.
When the last buffer leaves a project because it is unloaded, deleted, wiped, or
hidden with a destructive `bufhidden` policy, typst.nvim closes that project's
TOC window or TOC-owned quickfix list before pruning project state.
`toc.visible_layers` controls the initial visible layer set. Set any key to
`false` or set `toc.mappings.enabled = false` to leave TOC mappings untouched.

`compile.provider` defaults to the Typst CLI provider. Named providers include
`"generic"` and `"task"`, which run command arrays from `compile.generic` or
`compile.task`. Those command arrays support `{root}`, `{main}`, `{output}`,
`{profile}`, `{provider}`, `{source}`, and `{stdin}` placeholders. `{source}`
matches `{main}` for normal document compiles; for stdin-backed selected
fragments it is the originating buffer path when available. `{stdin}` is `1`
only when the command receives generated source on stdin. Advanced users may
also set `compile.provider` to a registered provider name, provider table,
callback, or Lua module name that implements `compile`, `start`, `stop`,
`status`, and `output`. For custom providers, `output(project, run_config)` is
called before compile/watch starts so events, status, and `:TypstInfo` expose
the provider's output path.
Project-specific task/generic providers are the Typst-native replacement for
Arara-style automation: set `compile.provider = "task"` or `"generic"` to route
`:TypstCompile` and `:TypstWatch` through `just`, `make`, `npm`, or another
repository task runner without encoding TeX directives in the document.
typst.nvim tracks handles returned from custom `compile` and `start` calls and
applies standard lifecycle state from synchronous or asynchronous callback
results. Returned handles remain active until a provider result arrives,
`stop()` reports `stopped = true`, or failed shutdown moves the handle into
retained-orphan tracking. Calling `stop()` while no compile or watcher is active
is a local no-op and does not call a custom provider's
`stop()` method; callback results for that case include `idle = true`.
Provider callbacks should return a terminal table such as
`{ code = 0, stdout = ..., stderr = ... }` or `{ code = 1, message = ... }`,
or a pending table with `pending = true` while work is still owned. Terminal
non-stale results update `project.services.compiler.last_result`, status, user
events, and output ownership consistently. A stop result means confirmed
termination only when it sets `stopped = true`; `stopped = false` or an
`orphaned` result keeps failure visible instead of pretending cleanup succeeded.
Retained orphans remain visible in reports/logs and keep leases guarded until a
real late exit releases them, `typst.reset({ force = true })` clears retained
state, or the user explicitly discards external compiler state with
`:TypstCompilerForceClear[!]`.
Runtime reset also clears global follow-buffer autocmds, deferred project
resolver tokens, buffer attachment debounce state, and loaded completion,
active conceal, and diagnostic caches through the runtime/cache hook registries.
Stable Tree-sitter parser callback guards are retained when needed to avoid
duplicate callback registration on live parsers.
Provider `on_finish()`-style callbacks are reserved for that real terminal exit;
stop callbacks are the settlement point for unconfirmed retention.
If an external compiler provider compile, watch, or stop request times out,
typst.nvim treats the provider as an unconfirmed writer and keeps its handle plus
output lease recorded. `:TypstCompilerForceClear[!] [project-key]` discards that
retained provider handle and output lease after the project is marked
`stopping_failed`; bang forces the discard even when that guard is not set. This
does not prove the provider process stopped. `:TypstStatusAll!` shows encoded,
command-safe `key_display` values for bufferless retained projects. Lua callers
may pass raw `project.key`, encoded `key_display` with `key_encoded = true`, or a
direct project object; command users should copy the encoded key from
`:TypstStatusAll!`. Lua code that already has a project object should pass
`project = project`, which is authoritative even when `key` is also present.
On Windows, normal compile/watch stop and restart paths target the process tree
with `taskkill /T` before falling back to direct process signaling, matching the
tree-aware reset/exit cleanup path used for wrapper scripts.

`:TypstClean` removes temporary Typst artifacts for the current project.
`:TypstClean!` also requests deletion of the resolved generated output file,
but unowned or changed outputs are skipped unless an API caller explicitly sets
`force = true`. Both forms refuse to run while a one-shot compile or watcher is
active.

`:TypstExport [profile|format]` compiles one or more artifact outputs and
records them in `project.services.artifacts.items`. Formats can be `pdf`, `png`,
`svg`, `html`, or `bundle` for the built-in Typst CLI path; named profiles come
from `exports.profiles`. If the command argument matches a profile name, the
profile wins even when it is also a built-in format name. `exports.default`
selects the profile used when no profile or format is passed. Profile entries
support `format`, `output_name`,
`output_dir`, `extra_args`, `inputs`, `font_paths`, `features`,
`creation_timestamp`, `package_path`, `package_cache_path`, `jobs`,
`diagnostic_format`, `timings`, `pages`, `pdf_standard`, `no_pdf_tags`, `ppi`,
and `pretty`, matching Typst CLI export flags. A profile entry may also set
`command`, `cwd`, and `stdout = true` to produce non-Typst-compile artifacts
such as `txt`; command placeholders include `{root}`, `{main}`, `{input}`,
`{output}`, `{output_dir}`, `{output_name}`, `{format}`, `{output_format}`,
`{typst_format}`, and `{profile}`. A profile entry may set `provider` to route
the whole export plan through a registered export provider; provider-owned
entries cannot be mixed with built-in/command entries in the same plan.
`:TypstArtifacts` lists registered outputs, `:TypstArtifactOpen [format]`
opens a matching artifact and prompts when several match, and
`:TypstArtifactClean [format]` deletes registered generated artifacts.
Programmatic artifact opens return `ambiguous_artifact` when no selector chooses
one artifact. `:TypstHtmlPreview` is the HTML workflow helper over
`TypstExport`, and `:TypstPresentation` is the presentation workflow helper for
a `presentation` export profile.

```lua
require("typst").setup({
  exports = {
    default = "release",
    profiles = {
      release = {
        { format = "pdf", pdf_standard = { "a-2b" } },
        { format = "html", pretty = true },
        { format = "png", pages = { "1" }, ppi = 192 },
      },
      txt = {
        format = "txt",
        output_name = "plain",
        command = { "my-typst-to-text", "{main}" },
        stdout = true,
      },
    },
  },
})
```

`:TypstEval {expression}` runs `typst eval --in <main>` in the current project
context, `:TypstEvalSelection` evaluates the selected Typst source, and
`:TypstInspect [expression]` opens serialized JSON for the expression or symbol
under the cursor. `:TypstInit [template] [directory]` uses `typst init` for
local or published templates; without a template it can select from the template
gallery. `:TypstTemplates` lists cached templates plus configured Universe-index
template metadata. Passing `offline = true` or `copy = true` to
`require("typst").init` uses the existing cached-template copier with package
containment and staging checks.

`:TypstProfile` runs a compile with Typst's `--timings` JSON output. `:TypstTest`
runs `tinymist test`, `:TypstCoverage` runs `tinymist test --coverage`, and
`:TypstBench` runs `crityp` when available; all can still be replaced with
registered development providers. Semantic editor helpers include
`:TypstInlayHintsToggle`, `:TypstCodeAction`, `:TypstColorInfo`,
`:TypstColorPresentation`, `:TypstLinks`,
`:TypstCodeLens`, `:TypstWorkspaceSymbols`, `:TypstReferences`,
`:TypstRenamePreview`, `:TypstSelectionExpand`, and `:TypstOnEnter`.
Tinymist is the default semantic engine; typst.nvim owns the commands,
scratch-buffer displays, and safe edit application. Extension plugins can
register `kind = "semantic"` providers and select one with
`integrations.semantic.provider = "name"`; semantic status, fallback diagnostic
ownership, and provider-backed semantic actions use the same resolver. Custom
semantic providers suppress compiler fallback diagnostics only when they
explicitly opt in with `owns_diagnostics = true`, `diagnostics = true`, or a
matching capability flag.

`viewer.provider` selects a named output opener. The default `"generic"` uses
`viewer.open` when configured and otherwise falls back to `vim.ui.open`.
Built-in provider presets include `"zathura"`, `"sioyek"`, `"skim"`,
`"sumatrapdf"`, `"mupdf"`, `"evince"`, `"okular"`, and `"qpdfview"`; they open
or reuse the output with conservative default args, and each preset can be
overridden through `viewer.providers.<name>`. When `viewer.open` is a string
executable or list prefix, `viewer.args` is passed to that viewer. Use
`{output}` inside an arg to control where the generated output path appears;
otherwise typst.nvim appends the output path after the configured args.
Successful one-shot compiles notify `viewer.reload(project, result, opts)` and
`preview.refresh(project, result, opts)` with `opts.source == "compile"`.
Watch cycles notify the same hooks with `opts.source == "watch"` and
`opts.watch == true`. `:TypstCompile!` and `:TypstWatch!` open the generated
output through typst.nvim's configured viewer; raw Typst CLI `--open` is
available with `compile.typst_open`.
`:TypstViewForward` is capability-gated: it calls `viewer.forward` when
configured, falls back to `preview.forward` when a preview source-sync callback
is configured, and otherwise reports that forward search is unavailable. The
PDF viewer presets do not claim forward or inverse synchronization by default
because normal Typst PDF output does not provide SyncTeX-style data. String or
list forward backends use `viewer.forward_args`, which support `{output}`,
`{main}`, `{root}`, `{line}`, and `{column}` placeholders, and they only run
when `viewer.capabilities.forward` or `viewer.capabilities.source_maps` is
declared.
`:TypstViewInverse [file] [line] [column]` handles source locations reported by
source-map-capable viewers. It calls `viewer.inverse` when configured, or opens
the reported source location directly when the selected viewer declares
`capabilities.inverse` or `capabilities.source_maps`. String or list inverse
backends use `viewer.inverse_args`, which support `{source}`, `{file}`,
`{path}`, `{output}`, `{main}`, `{root}`, `{line}`, and `{column}`
placeholders, and they only run when `viewer.capabilities.inverse` or
`viewer.capabilities.source_maps` is declared.
Preview/browser source-map integrations can use `preview.source_maps.forward`,
`preview.source_maps.inverse`, and `preview.source_maps.capabilities` to expose
support explicitly without claiming that native browser preview generates maps
by itself.

PDF viewer sync should stay capability-gated. The bundled viewer presets open
or reuse outputs, but they do not enable forward/inverse by default because
ordinary Typst PDFs do not carry SyncTeX. If a real source-map provider or
external bridge supplies PDF coordinates, configure the viewer command and
capabilities together:

```lua
require("typst").setup({
  viewer = {
    provider = "zathura",
    forward = "zathura",
    forward_args = {
      "--synctex-forward",
      "{line}:{column}:{source}",
      "{output}",
    },
    capabilities = {
      forward = true,
    },
  },
  preview = {
    source_maps = {
      provider = "my-pdf-source-map-provider",
      capabilities = {
        forward = true,
        inverse = true,
        source_maps = true,
      },
    },
  },
})
```

Equivalent recipes for `sioyek`, `skim`, and `sumatrapdf` should follow the
same rule: put command arguments in `viewer.forward_args`/`inverse_args`, and
only set `capabilities.forward`, `capabilities.inverse`, or
`capabilities.source_maps` when a provider can resolve Typst source positions
for that output.

`:TypstInfo`, `:TypstInfo!`, `:TypstCompileOutput`, `:TypstLog`, and
`:checkhealth typst` expose the resolved main file, root, compiler provider,
root/main decision sources, active profile, output path, last background
command, active compile/watch PID, Tinymist mode/client/capabilities, and
process working directory for debugging project decisions. The `:TypstInfo!`
bang form opens the detailed state in a scratch buffer. `:TypstLocks` lists
file-backed output locks, and `:TypstCleanLocks[!] [output-or-lockdir]` removes
stale locks, with bang reserved for explicit external lock recovery.
`:TypstReloadState` detaches and re-resolves the current buffer, preserving
active resources for the same project and stopping resources from any old
project that becomes detached. `:TypstClearCache` invalidates metadata,
package, symbol, index, and conceal caches. `:TypstInfo` and health also show
the active semantic provider, whether typst.nvim can see an attached Tinymist
Neovim LSP client for each project, and whether compiler diagnostics are
active, always enabled, off, or suppressed by semantic-provider ownership. With
the default `diagnostics.source = "fallback"`, compiler diagnostics publish
unless Tinymist owns diagnostics for the project through Neovim LSP/coc-tinymist
or a custom semantic provider explicitly declares diagnostic ownership. Use
`"always"` to keep compiler diagnostics beside semantic-provider diagnostics,
or `"off"` to disable compiler diagnostics completely.
`:TypstCompileOutput` opens the latest compiler stdout/stderr for the current
project. `:TypstLog`
opens the structured in-memory log, including command, cwd, root, main, and
output fields for compiler runs. `:TypstInfo` also shows viewer and preview
backend details. `:TypstInfo` and health report status through the active
compiler provider's `status(project)` method. If an external provider
compile/watch/stop timeout leaves an active output lease visible,
`:TypstCompilerForceClear[!] [project-key]` provides the explicit discard path.
Commands and Lua wrappers run from a dashboard, statusline, timer, or unrelated
buffer now fail closed with `no_project` unless the call passes a Typst
`bufnr`, direct `project`, or project key. This prevents status/preview/compile
helpers from accidentally creating or compiling the wrong project.

## Reset and recovery

`typst.reset({ force = true })` is the strongest in-process recovery path. It
stops compiler/preview resources, clears project state when resources are no
longer retained, removes follow-buffer autocmds, clears deferred resolver
tokens, forgets buffer debounce state, resets loaded completion/conceal/
diagnostic caches, and then allows setup to run again. Conceal keeps stable
Tree-sitter parser callback guards for live parsers so reset/re-enable cycles do
not stack duplicate callbacks. Without `force`, reset may retain projects whose
external providers or preview callbacks could not confirm a terminal stop; that
protects late callbacks from writing into discarded state.

Use `:TypstStop` or `:TypstStopAll` before cleaning outputs. `:TypstLocks`
shows file-backed output locks, including owner metadata when available.
`:TypstCleanLocks` removes stale locks only; `:TypstCleanLocks!` is for explicit
recovery when you have verified that the external writer is gone. If an
unconfirmed custom provider still owns an output lease,
`:TypstCompilerForceClear[!]` discards typst.nvim's retained handle, but it does
not kill or prove termination of the external process.

## Performance tuning

The expensive paths are project discovery, project indexing, completion scans,
conceal rendering, Tinymist requests, and preview refresh. Defaults favor a
complete editor workflow; large repositories, remote filesystems, and generated
documents may need tighter caps.

| Area | Settings | Guidance |
| --- | --- | --- |
| Main-file discovery | `project.import_scan`, `project.import_scan_max_files`, `project.import_scan_max_depth`, `project.import_scan_max_entries`, `project.import_scan_skip_dirs` | Import scanning is deferred from attach and uses a short-lived cache keyed by path/root/config/root metadata. It skips common generated/cache directories by default. Set `.typstmain` or `:TypstSetMain` for deterministic large projects; disable import scan on slow remote trees. |
| Project index | `project.index.max_file_bytes`, `project.index.large_file_policy`, `project.index.fs_watchers` | Keep `"skip"` for the cheapest unloaded-file behavior. Use `"headings-only"` when headings/imports matter, but it still reads oversized files. Use `"scan"` only for trusted projects where full oversized-file indexing is worth the cost. |
| Completion scans | `completion.path_scan_entry_max`, `completion.path_scan_max`, `completion.path_scan_cache_ms`, `completion.package_scan_max`, `completion.csl_scan_max`, `completion.font_scan_timeout_ms` | Lower caps when path/package completion is noisy. Set `path_scan_cache_ms = 0` to disable the brief directory cache; set `font_scan_timeout_ms = 0` to skip the `typst fonts` scan. |
| Conceal/rendering | `conceal.enabled`, `conceal.viewport_margin`, `conceal.categories`, `conceal.renderer.mode`, `conceal.renderer.image.enabled` | Disable categories you do not use before disabling conceal entirely. Reduce `viewport_margin` for very large buffers; image conceal is opt-in and should stay off unless terminal image rendering is part of the workflow. |
| Tinymist and async providers | `integrations.tinymist.lsp`, provider `timeout_ms` fields, `diagnostics.source` | Use `"detect"` if another plugin owns Tinymist startup. Prefer bounded provider timeouts and inspect stale callbacks or retained leases through `:TypstInfo!` and `:TypstLog`. |
| Native browser preview | `preview.browser.server`, `preview.browser.refresh_ms`, `preview.browser.max_artifact_bytes` | The local server caps headers and artifact size, then streams under-cap artifacts. Keep the cap enabled unless previewing trusted local artifacts in a controlled session. |

Use `:TypstInfo!`, `:TypstStatusAll!`, `:TypstDoctor`, `:TypstBugReport`,
`:TypstLog`,
`:checkhealth typst`, and `:TypstTelemetry` to decide which path is actually
slow before lowering caps.

## Troubleshooting

Start with `:checkhealth typst`, `:TypstInfo!`, `:TypstDoctor`,
`:TypstCompileOutput`, and `:TypstLog`. They show the resolved
root/main/output, Tinymist ownership, active compiler/preview state, last
command output, lifecycle/provider errors, and runtime ownership invariants.

- Wrong file compiles: inspect `root_source` and `main_source` in
  `:TypstInfo!`; use `:TypstSetMain`, `.typstmain`, or a setup `main` policy.
- `:TypstWatch` runs but preview does not refresh: check watcher status,
  `watch_unknown_status_lines`, output path, and preview backend in
  `:TypstInfo!`; human `typst watch` output can change between Typst versions.
- Watch reports success but no output appears: check
  `compile.watch_output_wait_ms`, `output_dir`, `output_name`, and filesystem
  permissions. Set `watch_output_wait_ms = 0` only when you want no delayed
  output wait.
- Compiler diagnostics disappeared after Tinymist attached: with
  `diagnostics.source = "fallback"`, compiler diagnostics are suppressed when
  Tinymist or another semantic provider owns diagnostics. Use `"always"` to
  keep compiler diagnostics beside semantic diagnostics.
- coc.nvim is active and native Tinymist did not start: configure
  `coc-tinymist` through Coc settings, or set
  `integrations.tinymist.lsp = "start"` if you intentionally want
  typst.nvim to start a separate nvim-lsp Tinymist client.
- Output path is already being written: another compile/watch/export still owns
  the path. Stop it with `:TypstStop`/`:TypstStopAll`, inspect active leases in
  `:TypstInfo!`, and use `:TypstCompilerForceClear[!]` only after handling the
  external process yourself.
- Preview stop is pending or failed: check `:TypstPreviewStatus` and
  `:TypstLog`. Native preview and delegated providers have different stop
  guarantees; pending provider stops are not treated as confirmed process exit.
- Tree-sitter-backed features are missing or stale: run `:checkhealth typst`
  and verify the Typst parser plus shipped queries load. Parser/query mismatch
  affects rich conceal, folds, motions, text objects, and package syntax.
- No Tree-sitter parser installed: project resolution, compile/watch, viewer,
  native preview, diagnostics, quickfix, output locks, and most completion
  sources still work. Syntax-aware conceal, folds, motions, text objects, and
  structural editing fall back or stay disabled until the parser is available.
- External provider timed out: typst.nvim keeps the provider state and output
  lease because timeout is not proof that the process stopped. Clear it only
  through `typst.reset({ force = true })` or
  `:TypstCompilerForceClear[!] [project-key]`.

## Development

Run the full local gate:

```sh
just check
```

Use `just test` when you only need the headless unit suite.
Use `just metadata` to regenerate the bundled Typst metadata artifacts from the
pinned Rust crates in `tools/typst-metadata`. The metadata pass reflects the
stdlib global/math scopes, function and element signatures, types, constants,
members, shorthands, symbols, emoji, categories, and deprecations into a tiny
JSON manifest plus schema-versioned MessagePack payloads. Runtime selection
supports multiple bundled versions through `data/typst/metadata/versions.json`,
uses `metadata_version` when configured, and reports a mismatch when it falls
back to a different bundled version. This reset currently ships generated Typst
`0.14.2` and `0.15.0` snapshots.

The old `nvim-oxi` prototype is preserved in `experiments/nvim-oxi/`. It is not
part of the plugin's main implementation.

See [docs/architecture.md](docs/architecture.md) for boundaries and roadmap.
See [docs/provider-contracts.md](docs/provider-contracts.md) for provider
behavior, [API.md](API.md) for the public API surface, and
[CREDITS.md](CREDITS.md) for ecosystem acknowledgements.
