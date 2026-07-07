# State Ownership Inventory

This inventory lists mutable state that survives a single function call. New
stateful modules should either appear here or be clearly owned by one of these
rows.

Backticked owner modules and reset/forget functions are normative and checked by
`tests/policy/state_inventory_spec.lua`. Conceptual ownership rows should avoid
backticking non-existent APIs.

| Owner module | State | Reset | Forget buffer | Forget window | Representative tests |
| --- | --- | --- | --- | --- | --- |
| `runtime.setup` | setup/configuration flags and package prewarm latch | `typst.reset()` through `runtime.setup.reset()` | n/a | n/a | `runtime_reset_hooks_spec.lua`, `setup_package_prewarm_spec.lua` |
| `runtime.resource_manifest` | ordered reset hook/cache manifest | `typst.reset()` through manifest phases | n/a | n/a | `runtime_reset_hooks_spec.lua`, `reset_manifest_contract_spec.lua` |
| `core.events` | nested User-event depth and deferred mutation queue | `core.events.reset()` | n/a | n/a | `runtime_reset_hooks_spec.lua`, `event_alias_spec.lua` |
| `core.log` | in-memory log entries and optional JSONL sink state | `log.clear()` / runtime reset | n/a | n/a | `log_spec.lua`, `bug_report_spec.lua` |
| `config` | current config, generation, read-only view cache, unknown keys | `config.setup()` / `typst.reset()` | n/a | n/a | `config_spec.lua`, `config_readonly_view_spec.lua` |
| `integrations.providers` | registered provider tables and provider generation | provider reset policy | n/a | n/a | `provider_contract_spec.lua`, provider matrix |
| `project.registry` / `project.store` | project tables, encoded keys, buffer-to-project map | `project.reset()` | `project.detach()` / `project_store.clear_buffer()` | n/a | `project_public_snapshot_immutability_spec.lua`, lifecycle matrix |
| `project.lifecycle` | deferred import-scan tokens | `project.lifecycle.reset()` | attach/detach overwrites tokens | n/a | `project_reload_transaction_spec.lua`, lifecycle matrix |
| `project.attachments` | buffer-local dirty debounce/index attachment state | `project.attachments.reset()` | `attachments.forget(bufnr)` | n/a | `ftplugin_attach_idempotence_spec.lua`, lifecycle matrix |
| `core.lifecycle` | buffer/window feature signatures and global cleanup autocmds | process reset and runtime re-source | `core_lifecycle.clear_buffer()` | `cache_registry.forget_window()` path | `window_option_restore_spec.lua`, `runtime_reset_hooks_spec.lua` |
| `project.services.compiler` | compiler provider binding, process/watch handles, output/status | project prune/reset | project detach through project state | n/a | compiler lifecycle/provider tests |
| `project.services.operations` | active project operation records | resource-manager reset | project cancel/detach paths | n/a | lifecycle matrix, provider matrix |
| `project.services.diagnostics` | per-source diagnostic buffers, quickfix-only items, last publish | diagnostics reset/project prune | `diagnostics.clear_buffer()` | n/a | diagnostics source/quickfix specs |
| `project.services.preview` | active preview route/session metadata and export pending state | preview reset/project prune | project detach/prune | n/a | preview lifecycle specs |
| `project.services.viewer` | viewer backend state and callback metadata | project prune/reset | project detach/prune | n/a | viewer integration specs |
| `project.services.artifacts` | generated artifact ownership metadata | artifacts reset/project prune | project detach/prune | n/a | `export_spec.lua` |
| `project.services.graph` | dependency graph roots/sources/dependencies | attach/reload/index reset | project detach/prune | n/a | `project_graph_modules_spec.lua` |
| `project.services.index` | index generation, cached files, watchers | index/cache reset | project detach/prune | n/a | index and lifecycle specs |
| `project.services.invalidation` | invalidation generation and reason metadata | project reset | project detach/prune | n/a | invalidation specs |
| `project.services.integrations` | last Tinymist/provider integration status | project reset/prune | project detach/prune | n/a | `tinymist_status_spec.lua` |
| `project.services.lifecycle` | last project transition metadata | project reset/prune | project detach/prune | n/a | `project_reload_transaction_spec.lua`, status tests |
| `core.operation` / `core.process` | active and retained process/operation handles | resource-manager reset | project operation cancellation | n/a | compiler lifecycle and operation specs |
| `resources.outputs` | file-backed output locks and last release failure | `outputs.reset()` | project prune releases owned outputs | n/a | output lock and lifecycle specs |
| `core.path_leases` | in-process path leases | `path_leases.reset()` | project release paths | n/a | output policy specs |
| `diagnostics` | namespace cache and namespace-to-source map | `diagnostics.reset()` | `diagnostics.clear_buffer()` | n/a | diagnostics namespace/source specs |
| `diagnostics.quickfix` | quickfix owner and window loclist owners | `diagnostics.reset()` | source/project clear rebuilds or clears | window loclist owner clear | quickfix ownership specs |
| `completion` | frontend sequence counters and source caches | `completion.reset()` | source-specific forget entries | n/a | completion generation/cache specs |
| `completion.context` | buffer-keyed completion context cache | `clear_cache()` via reset manifest | `clear_cache(bufnr)` | n/a | `completion_context_cache_reset_spec.lua` |
| `completion.packages` | package metadata cache and prewarm state | package reset/reset manifest | n/a | n/a | package/completion specs |
| `metadata` / `metadata.symbol` | generated metadata and symbol lookup caches | metadata/symbol reset | n/a | n/a | metadata/config docs specs |
| `core.treesitter` | collect cache keyed by buffer/range/query | `treesitter.forget()` via cache registry | `treesitter.forget(bufnr)` | n/a | Tree-sitter/conceal specs |
| `conceal` | decoration provider flag and window conceallevel owners | `conceal.reset()` | `conceal.forget()` / `detach()` | `_forget_window(winid)` | conceal/window restore specs |
| `conceal.matches` | chunked match cache and parser callback identity map | `matches.reset()` | `matches.forget(bufnr)` | n/a | conceal cache/parser specs |
| `conceal.match_query` | compiled Tree-sitter query cache | `match_query.reset()` | n/a | n/a | conceal query specs |
| `preview.follow_buffer` | optional global follow-buffer autocmd group and scheduled buffers | `follow_buffer.reset()` | n/a | n/a | `follow_buffer_lifecycle_spec.lua`, preview lifecycle specs |
| `preview.native.server` | native browser server, routes, and sessions | native server reset | project preview stop/prune | n/a | native preview lifecycle specs |
| `preview.source_maps.typst_query` | source-map query/cache state | reset manifest | n/a | n/a | source-map specs |
| `core.buffer` | buffer path cache and buffer lifecycle autocmds | `core.buffer.reset()` | buffer unload/delete clears entries | n/a | buffer/index specs |

## Rules

- Project-scoped state belongs in `project.services.*` unless it is truly
  process-global.
- Buffer/window state must have a cache-registry `forget`, `detach`, or
  `forget_window` entry.
- Optional global autocmds must be feature-gated. `preview.follow_buffer` is
  installed only when `preview.follow_buffer = true`; core cleanup autocmds stay
  installed because they own resource and window cleanup.
- Generated outputs must be leased through `resources.outputs` before writing.
- External processes must be represented by operation/compiler handles so reset,
  detach, and prune paths can stop or retain them deliberately.
