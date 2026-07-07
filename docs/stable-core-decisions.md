# Stable-Core Decisions

This file records release decisions that affect user-visible behavior but are
too policy-shaped for inline code comments. Update it when a stable-core
decision changes.

## Diagnostics External Paths

`diagnostics.external_paths = "bufadd"` remains the default for the current
stable-core candidate. It preserves inline diagnostics for unloaded dependency
files, which is the most complete default workflow.

The behavior is intentionally visible and bounded:

- `diagnostics.max_buffers_per_publish` caps hidden buffer creation.
- `:checkhealth typst` reports the current policy and cap.
- `:TypstInfo!` and `:TypstBugReport` include publish metadata.
- `quickfix-only` is the recommended profile for large projects, generated
  trees, remote filesystems, and users who do not want hidden buffers.
- `open-files-only` is the strictest policy and never adds external buffers.

Changing the default to `quickfix-only` before `1.0` is allowed only with a
changelog entry, migration note, and diagnostics external-path fixture updates.

## Native Preview Output

Native preview does not auto-run a compile or watch when a compiler output is
missing. `preview.provider = "native"` displays or serves an existing artifact;
it does not silently become a compiler driver.

Missing output stays a structured failure. Users should run `:TypstCompile`,
`:TypstWatch`, or an explicit export workflow before opening native preview.
Preview export profiles may create preview-specific artifacts, but that output
ownership is explicit and separate from normal compiler output ownership.

## Output Locks

Output locks are strict cross-Neovim ownership protection for live owners. A
live lock must block a conflicting writer unless the user chooses an explicit
force path. Dead-owner recovery is best-effort and must record what was cleaned
or retained.

Commands that remove locks must prove one of these conditions:

- typst.nvim owns the live in-process lease;
- the lock owner is stale/dead;
- the user requested force cleanup and accepted the risk.

`TypstCompilerForceClear` is a recovery tool for unconfirmed provider shutdown,
not a normal stop command.

## Event Payload Compatibility

For `1.0`, the stable event contract is the event name plus fields documented
in `API.md` and checked by `typst.api.contract`. New fields may be added when
they are backward-compatible.

Compiler event `provider` values describe the active bound compiler provider
that owns the work, not merely the current global config. If setup is called
while compile/watch work is active, event payloads continue reporting the
provider that produced the event.

## Command And API Error Boundaries

Stable commands must surface expected user failures as structured results, not
tracebacks or silent no-ops. Public APIs may return `(nil, err)` or
`{ ok = false, ... }`; command callbacks must pass those results through the
shared command result handler so no-project, missing-output, failed-reload, and
unavailable-provider cases are visible to users.

`config.get()` is a read-only indexable view, not an iterable table. LuaJIT used
by Neovim does not honor `__pairs` for this proxy. Extensions that need to
iterate or serialize config must use `config.snapshot()`.

## Tinymist Boundary

Tinymist is an optional semantic provider. The stable core is compile, watch,
stop, diagnostics publication, output viewing, project identity, resource
cleanup, and status/reporting without requiring Tinymist.

Tinymist-backed completion, code actions, workspace symbols, references,
colors, and richer semantic navigation are supported editor workflows. They
must degrade to structured unavailable results when no compatible Tinymist
client exists. coc-tinymist remains an ownership boundary in `"auto"` mode:
typst.nvim should detect it and avoid stealing LSP startup ownership.

## Compatibility Functions

Global compatibility functions and installed experimental helpers remain
available through the reset phase. They are not stable unless they appear in
the `API.md` stable-symbol block and `require("typst").stable_symbols()`.
Owned Neovim expression callbacks are limited to the documented
`typst_nvim_omnifunc`, `typst_nvim_indentexpr`, `typst_nvim_formatexpr`,
`typst_nvim_foldexpr`, and `typst_nvim_foldtext` globals. typst.nvim does not
overwrite an existing non-owned `_G.typst_nvim_*` value, and reset only removes
values it still owns.

After `1.0`, removing a global compatibility helper requires at least one
minor release of deprecation warning or an explicit major-version decision.

## Architecture Budget

Stable-core hardening is subtractive. Approved architecture changes are limited
to one reset owner, one preview controller boundary, one declarative runtime API
policy source, one pending/cancel contract, and one output lease owner. Larger
frameworks are deferred unless they replace existing owners in the same change.

Do not add a generic task framework, UI framework, provider marketplace/spec
DSL, broad picker framework, new event bus, or generated-docs pipeline for
internal modules during stable-core hardening. These may be reconsidered only
with a deletion plan and contract tests proving that older overlapping paths
were removed.
