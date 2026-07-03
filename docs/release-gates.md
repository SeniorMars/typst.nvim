# Release Gates

typst.nvim keeps the broad unit suite separate from a few release-specific gates.
These gates target areas where correctness depends on external frontends,
operating systems, or large-project latency.

## Stable Core

`tests/run_stability_gate.sh` is the feature-freeze gate for lifecycle-critical
contracts. It runs a focused set of API, command, cache, output-lock, provider,
process-tree, project lifecycle, compiler lifecycle, watch, resource-supervisor,
and native-preview fast-event specs. This gate should stay short enough for
every pull request and strict enough to block new feature work when core
stability regresses.

`tests/run_lifecycle_matrix.sh` is the broader lifecycle matrix. It covers
attach/detach, compiler, watch, preview, process, and resource-supervisor
combinations that are too broad for the short stability gate but still need a
named CI lane before stable-core release.

`tests/run_docs_contract.sh` is the docs and public-contract gate. It keeps
runtime API symbols, command registration, mappings, API docs, generated config
docs/schema, provider contracts, parity docs, and architecture ownership
contracts aligned.

The release checklist lives in `docs/stable-core-checklist.md`. Stable-core
release candidates should complete that checklist before broad feature work
resumes.

## Performance

`tests/run_performance_gate.sh` runs the normal runtime performance spec plus a
generated large-project fixture. The large fixture exercises project indexing,
cached index reads, narrow index accessors, project completion, package
completion, and bibliography diagnostics. The specs emit machine-readable JSON
reports under `$XDG_CACHE_HOME/performance-reports/`, and CI uploads those
reports as artifacts so latency trends can be audited across runs.

For longer trend runs, `just benchmarks` runs the same workloads multiple times
(`TYPST_NVIM_BENCHMARK_RUNS`, default `3`) and writes a summary under
`$XDG_CACHE_HOME/benchmark-reports/<timestamp>/summary.json`. That summary reports
per-metric sample counts, min, p50, p95, max, and worst budget ratio. It is a
maintainer benchmark suite, not a normal PR gate.

The budgets are intentionally regression gates, not proofs of final asymptotic
behavior. Bibliography, index, and package hot paths can still improve, but a
release should not regress the measured p95-style interactive paths without an
explicit budget update.

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
synchronous results, callback results, returned pending handles, raw handles,
timeouts, cancellation, duplicate callbacks, provider-thrown errors, and
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
