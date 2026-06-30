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
