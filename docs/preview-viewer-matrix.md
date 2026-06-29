# Preview Viewer Matrix

typst.nvim owns explicit preview workflow: selecting an output, opening a
viewer or browser shell, refreshing it after compile/watch cycles, and cleaning
preview-owned artifacts. Tinymist/coc-tinymist can own semantic export or LSP
features, but native preview remains a Neovim-side transport.

## Supported Targets

| Target | Command | Expected behavior |
| --- | --- | --- |
| Browser server | `just preview-matrix browser-server` | Opens a loopback preview URL through the default URL opener, serves the artifact, reloads after refresh, exposes shell controls, and accepts source-sync clicks only when a source-map provider is configured. |
| Browser file shell | `just preview-matrix browser-file` | Opens a generated HTML shell through the default URL opener, reloads from generated state, and disables source-sync clicks because there is no Neovim HTTP endpoint. |
| Safari | `just preview-matrix safari` | Optional installed-app check for Safari; also verify `preview.browser.performance = "safari"` for file-shell fallback and reload throttling. |
| Chrome | `just preview-matrix chrome` | Optional installed-app check for Chrome, launched through `open -a 'Google Chrome'` unless an opener override is passed. |
| Firefox | `just preview-matrix firefox` | Optional installed-app check for Firefox, launched through `open -a Firefox` unless an opener override is passed. |
| PDF viewer | `just preview-matrix preview`, `skim`, `sioyek`, `zathura`, `okular`, `evince`, `mupdf`, or `sumatrapdf` | Opens a preview-owned PDF through the configured viewer path. Browser shell controls and browser click sync do not apply. |

The harness keeps Neovim alive for
`TYPST_NVIM_PREVIEW_MATRIX_WAIT_MS` milliseconds, defaults to 120 seconds,
refreshes browser previews after `TYPST_NVIM_PREVIEW_MATRIX_REFRESH_AFTER_MS`,
and stops browser preview near the end of the run. It writes a JSON report to
`$TYPST_NVIM_TEST_XDG_ROOT/preview-matrix/report.json`.

## Manual Checks

1. Start the requested target with `just preview-matrix <target>`.
2. Confirm the artifact opens in the requested browser or viewer.
3. For browser targets, confirm the toolbar shows reload, zoom, fit, page, and
   source-sync controls.
4. For browser server targets, wait for the automatic refresh and confirm the
   displayed SVG generation changes.
5. For browser server targets, enable source sync and click the SVG. The report
   should record a `source_events` entry.
6. For browser file-shell targets, confirm source sync remains disabled.
7. Near the end of the browser run, confirm `:TypstPreviewStop` leaves the
   shell in a stopped state instead of continuing to reload.
8. For PDF viewer targets, confirm typst.nvim opens the preview-owned PDF path
   and does not replace the compiler output path.
9. For failed opener tests, configure `preview.browser.commands` with a missing
   executable and confirm `:TypstPreviewStatus!` reports the attempted URL,
   opener candidates, and copy hint.
10. For remote/WSL/SSH tests, confirm the reported URL can be opened manually or
    through an explicit opener such as `{ "wslview", "{url}" }`.

## Browser Performance

Use SVG browser output for fast preview loops when possible. A typical fast
profile limits the displayed page and writes preview-owned output:

```lua
exports = {
  profiles = {
    preview_svg = {
      output_format = "svg",
      extra_args = { "--pages", "1", "--input", "preview=true" },
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
```

For Safari lag or browsers that dislike frequent SVG iframe reloads, start with
`preview.browser.performance = "safari"`. That opts into file-shell transport,
slower polling, and a conservative reload throttle. Manual
`:TypstPreviewReload` bypasses the throttle when an immediate update is needed.

## PDF Viewer Sync

The PDF viewer presets are open/reuse presets, not SyncTeX claims. Keep
`capabilities.forward`, `capabilities.inverse`, and
`capabilities.source_maps` disabled unless a source-map provider or external
bridge can resolve Typst source positions for that output. Recipes for zathura,
sioyek, Skim, and SumatraPDF should configure `viewer.forward`,
`viewer.forward_args`, `viewer.inverse`, and `viewer.inverse_args` as templates,
then enable capabilities only with the matching source-map provider.

Template examples to apply only after a matching source-map provider or bridge
exists:

```lua
-- zathura forward-search template.
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
}
```

```lua
-- sioyek forward-search template.
viewer = {
  provider = "sioyek",
  forward = "sioyek",
  forward_args = {
    "--forward-search-file",
    "{source}",
    "--forward-search-line",
    "{line}",
    "{output}",
  },
  capabilities = {
    forward = true,
  },
}
```

```lua
-- Skim ships the displayline helper on macOS.
viewer = {
  provider = "skim",
  forward = "displayline",
  forward_args = {
    "-r",
    "-b",
    "{line}",
    "{output}",
    "{source}",
  },
  capabilities = {
    forward = true,
  },
}
```

```lua
-- SumatraPDF forward-search template for Windows.
viewer = {
  provider = "sumatrapdf",
  forward = "SumatraPDF.exe",
  forward_args = {
    "-reuse-instance",
    "-forward-search",
    "{source}",
    "{line}",
    "{output}",
  },
  capabilities = {
    forward = true,
  },
}
```

## Custom Openers

Pass a shell command with `{url}` only when you want to override the default URL
opener:

```bash
just preview-matrix browser-server 'xdg-open {url}'
just preview-matrix viewer 'my-pdf-viewer --reuse {url}'
```

This is intentionally a manual matrix. Unit tests cover route serving, file
shell state, export selection, cleanup, race protection, and source-sync request
plumbing; real browser and PDF viewer behavior still depends on external app
versions and OS integration.
