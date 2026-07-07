# Internal Contracts

Broader lifecycle and ownership notes live in `docs/architecture.md`.

## Coordinates

Internal positions use a single coordinate contract:

- `row`: zero-based buffer line.
- `byte_col`: zero-based UTF-8 byte offset within that line.

LSP clients may use UTF-8, UTF-16, or UTF-32 character offsets. Convert at the
LSP boundary with `typst.core.coordinates`; do not store LSP character offsets
in project, index, diagnostic, navigation, or edit state.

CLI diagnostics, bibliography parsers, Tree-sitter byte ranges, preview source
sync, and user-facing APIs should normalize into `row` plus `byte_col` before
publishing or storing results. Boundary code must clamp malformed positions to
the target line before passing them to Neovim APIs.

Diagnostic parsing may `bufadd()` unloaded files so Neovim can own diagnostics
for files outside the current window. To avoid unbounded hidden-buffer growth
from malformed provider output, new diagnostic buffers are capped by
`diagnostics.max_buffers_per_publish`; diagnostics for already accepted buffers
continue to publish within the same batch. Set the cap to `0` to disable it.
The cap applies to parser-created hidden buffers. `diagnostics.external_paths`
can opt out of parser-created buffers: `"quickfix-only"` keeps unopened-file
diagnostics as quickfix/location-list items without tracking them as
`vim.diagnostic` buffers, while `"open-files-only"` skips unopened files
entirely. Jumpable quickfix filename entries may still allocate Neovim buflist
entries; use `"open-files-only"` when no new buffer entries are acceptable.
quickfix-only path diagnostics must be stored by diagnostic source so explicit
quickfix reopen commands can rebuild the list after a user-owned quickfix
replacement.
Providers that return native `by_buffer` diagnostics are expected to supply
valid existing buffer numbers and are not path-expanded by the parser.

## Public Project Snapshots

`typst.project.get()`, `typst.project.all()`, `typst.project.snapshot()`, and
stable workflow methods that return project state (`attach`, `detach`,
`set_main`, `reload_state`, and `toggle_main().state`) return public snapshots.
They must not expose live project, service, buffer, resolution, or compiler
tables. Snapshots include a session-local project instance token so stale
snapshots cannot silently target a recreated project with the same key.
Internal code that needs mutation must use `typst.project.store`; the raw
`typst.project.registry` map is lower-level internal state and must not be
recommended in README/help examples.

## Configuration

`typst.config.get()` returns a read-only view. Use it for direct indexed reads.
Use `typst.config.snapshot()` for a traversable or mutable copy. Internal code
may use `unsafe_get()` only when it intentionally needs the live table, for
example to avoid proxy traversal limits in hot paths.

`setup(opts)` materializes typst.nvim read-only config views before merging, so
`config.setup(config.get())` remains a valid regression path.

## Generated Paths

Recursive deletion must use `typst.core.owned_path` or
`typst.core.files.delete_owned_tree`. Ownership proof should be:

- a known plugin/cache root that is not the project root;
- a sentinel file written by typst.nvim;
- a manifest of exact generated files.

Cleanup code should return structured refusal reasons such as
`unsafe_cache_dir`, `unsafe_fragment_source_dir`, `outside_root`, or
`root_refused` instead of silently skipping or deleting.

## Output Locks

`typst.resources.outputs` owns generated-output leases and file-backed lock
recovery. Callers must not bypass it with `core.path_leases` unless they are
low-level lease tests.

Recovery policy:

| Lock state | Acquire behavior | Cleanup behavior |
| --- | --- | --- |
| Active in-memory lease in this process | Blocked by the in-process lease | Never removed, even with bang |
| Lock owned by a live foreign PID | Blocked with `active_output` / `old_live_pid` | Removed only by bang plus explicit filter |
| Lock owned by a dead PID | Recovered before acquire | Removed by default cleanup |
| Missing, empty, unreadable, or corrupt owner inside grace period | Blocked as active/unknown | Kept unless bang plus explicit filter |
| Missing, empty, unreadable, or corrupt owner after grace period | Recovered before acquire | Removed by default cleanup |
| Same-PID lock without an in-memory lease | Recovered before acquire | Removed by default cleanup |

There is no age-only stale TTL for live PID locks: liveness wins over age.
Force cleanup must have an explicit output path, lock directory, or owner-file
filter so a broad bang cannot delete unrelated external locks.

## Operation Cancellation

`typst.core.operation` owns process-backed operations that are not already
represented by a project operation record. Runtime reset calls
`core.operation.reset()` through `resources.session` and
`runtime.resource_manager`; forced reset abandons unresolved callbacks after the
cancel attempt so late process exits cannot mutate stale project/cache state.
`resources.session.global_snapshot()` is the runtime-wide liveness surface for
global operation counts and blockers. New long-running work should still prefer
a project operation record or resource-session owner when a project exists.

## Buffer Path Selection

When multiple loaded buffers share the same file path, typst.nvim path lookup
prefers the current buffer if it is one of the matching loaded buffers.
Otherwise it chooses the highest-numbered loaded buffer. APIs that must operate
on a particular source buffer must pass `bufnr`; path-only lookup is a
best-effort compatibility policy for diagnostics, source sync, bibliography,
and completion callers.

`typst.project.services.operations.cancel_project()` returns both counters and
per-record `outcomes`. The outcome names are stable internal policy:

| Outcome | Active record | Retained record | Meaning |
| --- | --- | --- | --- |
| `cancelled` | cleared | no | Cancellation was confirmed. |
| `retained` | cleared | yes | A cancellable handle became an orphan-retained operation. |
| `uncancellable` | cleared | yes | A live handle had no cancellation API. |
| `failed` | kept | no | Cancellation failed and liveness is still unresolved. |
| `stale` | cleared | no | The record had no live handle and was only bookkeeping. |

Reset and exit cleanup may report retained or failed outcomes, but they must not
silently prune a project while retained operations or active leases still keep
the project discoverable.

## Compiler Output Paths

Workflow entry points must not throw for user-configured output paths. The
low-level `compiler.output_path.output_path()` helper remains strict, but
compile/watch/export-style controllers should call the non-throwing safe helper
and return a structured `output_path_invalid` result before acquiring an output
lease or spawning a process.

## Conceal

Typst conceal uses Tree-sitter only to locate candidate syntax. Lua rules decide
whether a candidate is safe and meaningful to conceal:

```text
Tree-sitter query -> capture name -> rule registry -> normalized match -> reveal filter -> extmark renderer
```

Rule resolvers must be side-effect-free. They may inspect configuration,
metadata, custom conceal maps, parser nodes, and shadowing state, but must not
mutate project, compiler, preview, or cache state.

Implicit Typst names such as symbols, math fonts, and math wrapper functions
must be checked against the conceal shadow state before replacement. If a local
definition, import, or wildcard import can shadow the name, the rule should fail
closed and leave source text visible.

Every Unicode replacement must pass conceal display-safety checks before it is
rendered. Multi-cell, combining, virtual-text, or image-style replacements
belong behind an explicit renderer mode instead of the default extmark
`conceal` path.

Reveal is window-local and happens after match collection. A cursor move should
reuse collected matches for the same viewport and only re-run the reveal filter.
Match collection is invalidated by conceal generation, config generation,
metadata generation, custom conceal generation, buffer changes, and
Tree-sitter changed-tree ranges.

New Tree-sitter captures require parser compatibility coverage. Add query
compatibility tests and health output before rules depend on new Typst parser
node names.
