# typst.nvim Stability Policy

`typst.nvim` is stable only when core lifecycle behavior is deterministic and
recoverable. Stable does not mean every workflow is finished.

## Scope And Non-Goals

The stable-core scope is project identity, compile/watch, output ownership,
preview lifecycle, reset/prune/exit recovery, diagnostics publication, public
API failure behavior, and health/status reporting.

Stable-core hardening is not a license to build more frameworks. These are
explicit non-goals unless a patch removes older complexity at the same time:

- generic task framework;
- UI element or layout framework;
- provider marketplace or provider spec DSL;
- broad picker abstraction;
- generated documentation for every internal module;
- new event bus;
- generalized diagnostic-tool engine.

## Stability Tiers

| Tier | Contract |
| --- | --- |
| Stable core | Project identity, compile/watch/stop, output leases, reset/recovery, status/health, stable API symbols, and documented commands. |
| Supported workflow | Preview, viewer, diagnostics, completion, conceal, index, export/render/clean, and provider adapter behavior covered by the stability/provider gates. |
| Experimental integration | Optional integrations such as Tinymist extras, delegated preview, picker adapters, and provider-specific extensions. They must fail closed with structured errors. |
| Internal implementation | Module layout and helper functions not listed in `API.md`; these may move behind compatibility facades and contract tests. |

## Stability Guarantees

| Guarantee | Policy |
| --- | --- |
| No silent wrong project | Compile, watch, preview, navigation, and edit commands must not silently target a different main file than the resolved project. |
| No orphaned user state | Buffer/window options, quickfix/loclist ownership, preview routes, output leases, and autocmds must be restored or explicitly retained with a reason. |
| No hidden destructive cleanup | Output/cache/artifact deletion must prove ownership, freshness, and inactive state unless `force=true`. |
| No unbounded background work | Import scan, index, completion, diagnostics, source maps, and preview exports must have caps and status visibility. |
| No provider ambiguity | Providers share the common result and pending-handle contract documented in `docs/provider-contracts.md`. |
| No accidental API expansion | The stable API is the exact dotted-symbol list in the `API.md` stable-symbol block and `typst.stable_symbols()`. |
| Recoverable failure modes | User commands and public APIs should return structured `{ ok=false, reason, message }` for expected runtime/config failures. |
| Cross-platform behavior is tested | Windows paths, process-tree cancellation, spaces, case, and shell-free argv handling stay in CI gates. |
| Respectful Neovim integration | typst.nvim restores options/lists/mappings it owns and avoids clearing user-owned state. |

## Compatibility Matrix

| Component | Supported | Tested in CI | Degraded mode |
| --- | --- | --- | --- |
| Neovim 0.11.0 | yes | yes | none |
| Neovim stable | yes | yes | none |
| Neovim nightly | best effort | yes | failures triaged |
| Typst 0.14.x | yes | partial | reduced metadata compatibility |
| Typst 0.15.x | yes | yes | normal |
| Tree-sitter Typst parser | recommended | pinned/no-parser lanes | syntax-aware features degrade |
| Tinymist native LSP | optional | fake client and smoke tests | fallback project/completion paths |
| coc-tinymist | optional | detection tests | fallback diagnostics suppressed |
| Windows | yes | edge gate | platform-specific process/path fallback |
| typst-preview.nvim | compatibility | delegation smoke tests | native preview fallback |

## API And Deprecation Policy

Before `1.0`:

- Commands are stable unless documented experimental.
- Exact symbols in the `API.md` stable-symbol block are stable for the current
  `API_VERSION`.
- Experimental symbols may change with changelog notes.
- Internal modules may change without notice.
- Provider contracts may tighten only with docs, examples, and migration notes.

After `1.0`:

- Stable commands, config keys, API symbols, and provider contracts require a
  deprecation period of at least one minor release.
- Removed symbols should leave compatibility shims that warn once when feasible.
- Patch releases are bug fixes only.
- Minor releases add backward-compatible features.
- Major releases are reserved for breaking API/config/provider changes.

## Release Checklist

- `tests/run_stability_gate.sh`
- `tests/run_docs_contract.sh`
- `tests/run_lifecycle_matrix.sh`
- `tests/run_provider_matrix.sh`
- `tests/run_performance_gate.sh`
- Windows edge gate
- Manual smoke checklist from `docs/release-gates.md`
- Stable-core policy decisions in `docs/stable-core-decisions.md` reviewed
- Changelog entry for every stable API/config/provider behavior change
- Bug-report artifact from `:TypstBugReport` or `:TypstSupportBundle` attached
  to any unreproduced lifecycle failure before release

## Feature Freeze Rule

During stable-core hardening, no new workflow feature should merge if it
expands public API, provider behavior, lifecycle state, generated output, or
background work without matching docs, caps, structured failure paths, and
regression tests.

## Subtractive Architecture Rule

Architecture changes should remove more lifecycle surface area than they add.
The approved stable-core architecture budget is one reset manifest, one preview
controller boundary, one runtime API policy table, one pending/cancel contract,
and one output lease owner. A broader abstraction needs a deletion plan,
migration tests, and an explicit update to `docs/stable-core-decisions.md`.
