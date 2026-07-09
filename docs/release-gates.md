# Release Gates

typst.nvim keeps the broad unit suite separate from a few release-specific gates.
These gates target areas where correctness depends on external frontends,
operating systems, or large-project latency.

## Stable Core

`tests/run_stability_gate.sh` is the feature-freeze gate for lifecycle-critical
contracts. It runs a focused set of API, command, cache, output-lock, provider,
process-tree, project lifecycle, compiler lifecycle, watch, resource-manager,
and native-preview fast-event specs. This gate should stay short enough for
every pull request and strict enough to block new feature work when core
stability regresses.

`tests/run_lifecycle_matrix.sh` is the broader lifecycle matrix. It covers
attach/detach, compiler, watch, preview, process, and resource-manager
combinations that are too broad for the short stability gate but still need a
named CI lane before stable-core release.

`tests/run_docs_contract.sh` is the docs and public-contract gate. It keeps
runtime API symbols, command registration, mappings, API docs, generated config
docs/schema, provider contracts, parity docs, and architecture ownership
contracts aligned.

The release checklist lives in `docs/stable-core-checklist.md`. Stable-core
release candidates should complete that checklist before broad feature work
resumes.

Lifecycle state machines and ownership invariants live in
`docs/architecture-lifecycle.md`. Release, compatibility, and deprecation policy
live in `docs/stability-policy.md`. Changes to project, compiler, preview,
provider, cache, or public API behavior should update those documents when the
invariant or release contract changes.

Maintainer inventories for service ownership, event ordering, cache
invalidation, autocmd lifecycle, and stable-core policy choices live in
`docs/services.md`, `docs/event-ordering.md`, `docs/cache-invalidation.md`,
`docs/autocmd-lifecycle.md`, and `docs/stable-core-decisions.md`. Stable-core
release candidates should treat those as release artifacts: if behavior changes
there, the matching inventory should change in the same patch.

## Performance

`tests/run_performance_gate.sh` runs the normal runtime performance spec plus a
generated large-project fixture. The large fixture exercises project indexing,
cached index reads, narrow index accessors, project completion, package
completion, TOC collection/follow coalescing, conceal first render and redraw
windows, and bibliography diagnostics. The startup spec records setup latency
with default and optional features; `tests/unit/startup_lazy_modules_spec.lua`
keeps heavyweight health, preview, Tinymist, package-scan, metadata, and viewer
modules out of basic setup. The specs emit machine-readable JSON reports under
Neovim's `stdpath("cache")/typst.nvim/performance-reports/`, and CI uploads
those reports as artifacts so latency trends can be audited across runs.

For longer trend runs, `just benchmarks` runs the same workloads multiple times
(`TYPST_NVIM_BENCHMARK_RUNS`, default `3`) and writes a summary under
Neovim's `stdpath("cache")/typst.nvim/benchmark-reports/<timestamp>/summary.json`.
That summary reports per-metric sample counts, min, p50, p95, max, and worst
budget ratio. It is a maintainer benchmark suite, not a normal PR gate.

The budgets are intentionally regression gates, not proofs of final asymptotic
behavior. Bibliography, index, and package hot paths can still improve, but a
release should not regress startup laziness, TOC cursor-follow coalescing,
conceal large-file range behavior, or the measured p95-style interactive paths
without an explicit budget update.

## Manual Smoke

Stable-core release candidates need a small manual smoke pass in addition to
headless gates. The minimum checklist is:

- Fresh install with `typst` only and no Tree-sitter parser.
- Fresh install with Tree-sitter parser and no Tinymist.
- Tinymist native LSP auto-start with built-in Neovim LSP.
- coc-tinymist present; `integrations.tinymist.lsp = "auto"` must not steal
  native LSP ownership.
- Compile, watch, stop, reset, and force-clear recovery.
- Native viewer preview.
- Native browser preview.
- typst-preview.nvim delegation.
- Diagnostics external paths with `bufadd`, `quickfix-only`, and
  `open-files-only`.
- Windows path with spaces and UNC-like paths on a real Windows runner.

For a short noninteractive local smoke of the native browser preview matrix,
run:

```sh
TYPST_NVIM_PREVIEW_MATRIX_WAIT_MS=3000 \
TYPST_NVIM_PREVIEW_MATRIX_REFRESH_AFTER_MS=500 \
TYPST_NVIM_PREVIEW_MATRIX_STOP_AFTER_MS=1500 \
bash tests/run_preview_matrix.sh browser-server
```

That command verifies the preview matrix harness, export provider, native
browser route, refresh callback, and stop path. It does not replace the real
manual visual pass.

## Windows Edges

`tests/run_windows_edge.sh` isolates process-tree shutdown, reset ownership, and
path-resolution edge cases. CI runs it on `windows-latest` so Windows process
and path behavior is covered by a real Windows runner rather than by Unix
assumptions.

## mini.test Pilot

`tests/run_minitest.sh` runs `tests/minitest/test_*.lua` through `mini.test`.
This lane is for new coverage that benefits from managed child Neovim
processes, case names, hooks, and parametrization. The existing plain Lua
headless specs remain the default unit and integration coverage.

## Completion Frontends

`tests/run_frontend_smoke.sh` loads real `nvim-cmp` and `blink.cmp` modules in
CI, exercises the typst.nvim source adapters against mocked Tinymist responses,
and drives real headless popup sessions through each frontend's UI API. It
verifies the `nvim-cmp` refresh hook path and separately checks that cached
adapter output still carries Tinymist text edits, snippets, additional edits,
and commands. Full visual insertion and frontend-specific refresh rendering
remain owned by the frontend and are outside the headless CI contract.

The same gate also invokes `tests/run_playwright_smoke.sh`. That lane launches a
headless Neovim native browser preview, opens the local preview URL with
Playwright Chromium when Playwright is installed, and verifies the shell DOM plus
`state`, `artifact`, and `source-sync` browser requests. It skips by default
when Node or Playwright is unavailable. Set `TYPST_NVIM_REQUIRE_PLAYWRIGHT=1`
after installing Playwright, for example `npm --prefix .deps/playwright-smoke
install --no-save --no-package-lock playwright &&
.deps/playwright-smoke/node_modules/.bin/playwright install chromium`, to make
the browser smoke mandatory. CI installs Chromium this way and treats the
Playwright smoke as part of the frontend gate.

## Watch Output

Typst watch parsing is intentionally fixture-gated for supported Typst minor
versions. Typst currently exposes human-readable watcher output rather than a
structured event stream, so `tests/fixtures/watch-output/*.txt` is the support
contract. New supported Typst minors should add or refresh a fixture.

## Provider Matrix

`tests/run_provider_matrix.sh` shards fake-provider coverage into `compiler`,
`async`, `workflow`, and `tools-viewer` suites. CI runs those suites on
`ubuntu-latest`, `macos-latest`, and `windows-latest` with stable Neovim and
the current supported Typst minor, plus a Linux nightly-Neovim compiler-provider
smoke lane. Provider behavior is tested with fake providers rather than real
third-party tools whenever possible. Release candidates should keep coverage for
synchronous results, callback results, explicit pending handles, userdata
handles, timeouts, cancellation, duplicate callbacks, provider-thrown errors, and
malformed results.

External provider docs live in `docs/provider-contracts.md`. Any provider
contract change should update that file and add or refresh a fixture in the same
patch.

## Public API Stability

The stable Lua surface is the exact dotted symbol list documented in `API.md`
and returned by `require("typst").stable_symbols()`. Installed namespaces may
contain experimental helpers; those are reported by `experimental_symbols()` and
may change between minor releases. Stable symbols need a migration note,
compatibility alias, or explicit major version decision.

For this reset-phase hardening release, call out the pre-1.0 API tier narrowing
explicitly in release notes: API level remains 1, but stability is narrowed from
namespace-level wording to exact dotted symbols. Installed helpers remain
available; use `stable_symbols()` and `experimental_symbols()` to audit
compatibility.

Flat workflow aliases are intentionally not exported. CI checks command and API
documentation against the runtime registry to avoid unintentional public surface
drift. `tests/run_docs_contract.sh` is the dedicated release gate for this
policy and runs the runtime API contract, docs contract, generated config
schema/doc contract, alias policy, provider contract, parity-doc checks, and
architecture ownership policy together. `tests/run_api_stability.sh` remains a
compatibility wrapper around the same gate. Config reference output is generated
with `just config-docs`, which refreshes `docs/config-reference.md` and
`data/config-schema.json` from the runtime defaults.
