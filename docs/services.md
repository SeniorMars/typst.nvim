# Project Services

Project services are per-project state tables under `project.services`. They
exist so status, cleanup, bug reports, and lifecycle tests can inspect one
project without asking every workflow module separately.

Services are internal implementation state unless a field is explicitly exposed
through `API.md`, a command report, or a provider contract. Public code should
use commands and API methods, not mutate service tables directly.

## Inventory

| Service | Owner | Main state | Reset / prune rule |
| --- | --- | --- | --- |
| `compiler` | `typst.compiler` | active compile process, watcher, output path, output lease, provider label, generations, last result/error | Stop active work before pruning when possible. Retain unconfirmed writers or release leases only through compiler/resource helpers. |
| `preview` | `typst.integrations.typst_preview` and native preview modules | active/opening/stopping flags, backend/provider labels, pending open handle, generation, last result/error | Pending callbacks must check project key, instance id, generation, and prune state before mutating. |
| `viewer` | `typst.viewer` | viewer backend, command, last source-sync state | Cleared with project state; does not own compiler output. |
| `diagnostics` | `typst.diagnostics` | per-source diagnostic tables, quickfix-only path diagnostics, last publish metadata | Source clears only clear their namespace/source data. Project prune clears all namespaces owned by the project. |
| `artifacts` | workflow/export/render/preview producers | discovered artifacts, producer metadata, format/path records | Artifacts are reports of produced files. Deleting files still requires output/artifact ownership checks. |
| `operations` | `typst.core.operation` plus project operation service | active and retained operation ids, summaries, cancellation status | Retained operations remain visible until they settle or explicit cleanup accepts the retained state. |
| `graph` | project dependency graph modules | sources, dependencies, dependency generation, roots | Invalidated by attach/detach, file writes, import scan changes, and explicit project reload. |
| `index` | project index modules | headings, labels, definitions, bibliography, per-file index data, index generation | Mark dirty on source edits and refresh lazily. Cached reads should use generation checks. |
| `invalidation` | project invalidation service | dirty buffers, reasons, generation counters | Reset with project services; used to avoid stale index/source-map results. |

## Ownership Rules

- A service owns state shape, mutation, and snapshot formatting for its domain.
- `project.services.snapshot()` is read-only reporting glue.
- Resource cleanup may observe services but should call owner APIs to stop,
  cancel, release, or retain state.
- Async callbacks that mutate a service must check the project key and
  `instance_id`; callbacks from a pruned or replaced project are stale.
- Services may add fields for diagnostics and reports, but fields become stable
  only when documented in the public API or provider contract.

## Status And Bug Reports

Every service should provide a bounded snapshot suitable for `:TypstInfo!`,
`:TypstStatusAll!`, and `:TypstSupportBundle`. Snapshots must avoid raw handles,
unbounded logs, and private paths unless the report redaction layer can scrub
them.
