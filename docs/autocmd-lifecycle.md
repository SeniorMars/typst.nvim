# Autocmd Lifecycle

Buffer-local Typst lifecycle autocmds are installed by
`lua/typst/project/lifecycle/buffers.lua`. One augroup is created per buffer
with `clear = true`; repeated ftplugin loads, setup calls, and reattach attempts
must replace handlers instead of stacking them.

## Buffer-Local Events

| Event | Purpose | Invariant |
| --- | --- | --- |
| `BufWinEnter`, `WinEnter` | Reapply buffer-local features and open follow-TOC state when a Typst buffer becomes visible. | Reapplication is idempotent and should not duplicate mappings, folds, conceal, or omnifunc state. |
| `BufEnter` | Refresh follow-TOC open state for the active buffer. | Does not reattach or rebuild project state. |
| `CursorMoved`, `CursorMovedI` | Schedule follow-TOC updates. | Cursor movement should not mark the project index dirty. |
| `TextChanged`, `TextChangedI`, `BufWritePost` | Mark project index dirty when the source changed and schedule TOC refresh. | Dirty marks are debounced by buffer/project state and do not stack duplicate timers. |
| `BufFilePost` | Migrate persisted main-file mappings after `:saveas` or rename, then reattach the buffer. | Explicit main choices follow the renamed buffer before project resolution runs again. |
| `BufHidden` | Detach when the buffer's `bufhidden` policy unloads, deletes, or wipes it. | Hidden-but-loaded buffers remain attached. |
| `BufUnload`, `BufDelete`, `BufWipeout` | Detach the buffer and allow project prune/resource cleanup. | Detach is safe to call more than once for the same buffer. |

## Global Runtime Events

Runtime setup owns global exit cleanup, preview follow-buffer hooks, command
registration, and shared reset hooks. Runtime reset must remove global hooks it
owns and clear buffer-local groups for buffers still known to typst.nvim.

## Tests

`tests/unit/ftplugin_attach_idempotence_spec.lua` verifies buffer-local autocmds
do not stack. `tests/unit/runtime_reset_hooks_spec.lua` verifies global follow
hooks are replaced on reconfigure and removed on reset. Lifecycle matrix tests
cover detach, prune, reset, and exit cleanup ordering.
