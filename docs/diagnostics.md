# Diagnostics Path Policy

Typst compiler diagnostics can refer to files that are not currently loaded in
Neovim. `diagnostics.external_paths` controls whether typst.nvim creates hidden
buffers for those paths, stores filename-only quickfix entries, or skips them.

| Mode | Buffer diagnostics | Quickfix/location list | Hidden buffers | Intended use |
| --- | --- | --- | --- | --- |
| `bufadd` | Publishes diagnostics through `vim.diagnostic` for current and external files. | Mirrors diagnostics when `diagnostics.use_quickfix` is enabled. | Creates unloaded buffers for external files, capped by `diagnostics.max_external_buffers`. | Rich default behavior for normal local projects. |
| `quickfix-only` | Publishes diagnostics only for already loaded buffers. | Keeps unopened-file diagnostics as filename-based quickfix/location-list items. | typst.nvim does not call `bufadd()` for unopened files. Neovim may still allocate buflist entries when jumping to filename items. | Large, generated, remote, or package-heavy projects where hidden diagnostic buffers are undesirable. |
| `open-files-only` | Publishes diagnostics only for already loaded buffers. | Skipped unopened files are not added by typst.nvim. | Never creates buffers for unopened diagnostic paths. | Strict no-new-buffer policy. |

The cap in `diagnostics.max_external_buffers` applies only to parser-created
hidden buffers in `bufadd` mode. Existing loaded buffers and paths accepted
earlier in the same publish batch continue to receive diagnostics.
Set the cap to `0` to create no hidden buffers for unopened diagnostic paths.
When `bufadd` reaches the cap, `diagnostics.overflow = "quickfix-only"`
preserves diagnostics as quickfix-only items. Set
`diagnostics.overflow = "drop"` to discard capped unopened-file diagnostics
instead.
The old `diagnostics.max_buffers_per_publish` key is accepted as a deprecated
setup-time alias for `diagnostics.max_external_buffers`; new configs should use
the clearer name.

`quickfix-only` diagnostics are stored by diagnostic source in the project
diagnostics service. That lets `:TypstDiagnostics` rebuild source-owned
quickfix/location-list entries after a user command replaces the global list.

Reports expose the last publish policy. Use `:TypstInfo!` to inspect
`diagnostic external paths`, added buffer counts, quickfix-only counts, skipped
counts, and the first skipped path.

Regression coverage lives in:

- `tests/unit/diagnostics_external_paths_modes_spec.lua`
- `tests/unit/diagnostics_buffer_limit_spec.lua`
- `tests/unit/diagnostics_quickfix_source_rebuild_spec.lua`
