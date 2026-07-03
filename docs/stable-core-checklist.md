# Stable Core Checklist

Use this checklist as the blocking gate for the first stable-core release. New
feature work should not bypass it; if a feature touches one of these contracts,
the feature patch updates the matching tests and docs in the same change.

## Required workflows

- [ ] Open Typst file attaches exactly once.
- [ ] Main resolution is explainable and deterministic.
- [ ] Compile succeeds and fails with diagnostics.
- [ ] Watch starts, reports cycles, restarts, and stops.
- [ ] Stop works on Unix, macOS, and Windows.
- [ ] Output leases release on confirmed stop, success, and failure.
- [ ] Unconfirmed providers retain state and are force-clearable.
- [ ] Reset does not drop live or retained resources silently.
- [ ] Buffer detach prunes only when no resources remain.
- [ ] Health reports missing typst, missing Tinymist, missing parser, output
      locks, and retained operations.

## Required public contracts

- [ ] Stable symbols match `API.md`.
- [ ] Commands match help docs.
- [ ] Events and aliases match API contract.
- [ ] Config docs and schema are generated from defaults.
- [ ] Provider kinds and fixture cases match provider docs.

## Required negative tests

- [ ] Missing typst executable.
- [ ] Bad `output_dir`.
- [ ] Invalid provider handle.
- [ ] Provider never calls back.
- [ ] Provider callback duplicates.
- [ ] Process kill timeout.
- [ ] Windows child process.
- [ ] Live foreign output lock.
- [ ] Corrupt output lock.
- [ ] Parser missing.
- [ ] Tinymist missing.
- [ ] coc active.
- [ ] Non-Typst buffer action fails closed.

## Merge policy

- [ ] No new feature PR merges while any stable-core checklist item is failing.
- [ ] Any new async, process, or provider feature adds a reset or cancel test.
- [ ] Any new generated-output feature adds an output-lock test.
- [ ] Any new command updates help docs or generated command docs.

## Feature re-entry checklist

- [ ] Does not mutate project service tables outside the owning service module.
- [ ] Uses `resources.outputs` for generated artifacts.
- [ ] Uses `provider_adapter` for provider callbacks and results.
- [ ] Uses `core.process` or `core.operation` for process lifecycle.
- [ ] Has reset, detach, and `VimLeavePre` behavior.
- [ ] Has at least one unit test and one integration or smoke test if it touches
      Neovim state.
- [ ] Has docs or a generated docs entry.
- [ ] Adds telemetry or debug info if it can be slow or async.
- [ ] Does not expand stable API unless `API.md` and tests are updated.
