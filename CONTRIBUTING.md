# Contributing

Run the local gate before sending patches:

```sh
just check
```

For focused work, use:

```sh
just test
just minitest
just fmt-check
just health
```

`just minitest` runs the `mini.test` pilot suite. It requires `mini.nvim` on the
test runtimepath; set `TYPST_NVIM_TEST_MINI=/path/to/mini.nvim` or clone it to
`.deps/mini.nvim`.

Architecture and contracts:

- `ARCHITECTURE.md`: lifecycle, ownership, and service-boundary invariants.
- `docs/provider-contracts.md`: external provider return, callback, timeout,
  and cancellation rules.
- `docs/internal-contracts.md`: coordinate and maintainer contract notes.
- `docs/release-gates.md`: CI matrix, performance gates, and release policy.
- `docs/api.md` and `API.md`: public Lua API stability surface.

When changing async lifecycle code, add a deterministic headless regression
test. Prefer fake providers or fake commands over timing-sensitive sleeps.

When changing cleanup code, use `typst.core.output_policy` for generated output
trees, or `typst.core.owned_path` for lower-level ownership checks. Do not add
ad hoc recursive deletion.

When changing provider-facing APIs, update `docs/provider-contracts.md` in the
same patch.
