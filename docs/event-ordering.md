# Event Ordering

typst.nvim emits public `User` events after state transitions have enough data
for automation to inspect a stable payload. Event names and stable payload
fields are documented in `API.md`.

## General Rules

- Project payloads include the project key, root, main, buffer, and compiler
  provider identity when known.
- Compiler provider identity comes from the active bound compiler provider, not
  merely from current global config.
- Event payloads are snapshots. Handlers should not mutate internal services
  synchronously; schedule follow-up API calls when mutation is needed.
- New payload fields may be added when backward-compatible. Removing or
  changing stable fields follows the stability policy.

## Buffer Attach / Detach

Expected attach path:

1. Resolve root and main.
2. Create or update the project and buffer membership.
3. Install buffer-local features and autocmds idempotently.
4. Emit buffer/project attach events.
5. Schedule deferred import scan or index refresh if configured.

Attach finalization failures are not hidden. The project may remain attached in
a degraded state, but lifecycle transition metadata records
`finalization_error`, and attach events carry `finalization_ok = false`.

Project reload must not detach the previous project before a replacement attach
has succeeded. If reload fails, command/API callers receive a structured
`reload_failed` result and typst.nvim preserves or restores the previous buffer
membership when possible.

Transition snapshots use `previous_stop_requested` for old-project cleanup. That
field means typst.nvim invoked the resource-manager stop/prune path; it is not a
confirmed shutdown result. Confirmed compiler shutdown remains reported by the
compiler/operation state and stop events.

Expected detach path:

1. Emit buffer-detach events while the project is still inspectable.
2. Remove buffer membership and buffer-local lifecycle state.
3. Prune the project only when no buffers or active resources remain.
4. Emit prune events for registry removal, not for every buffer detach.

## Compile

Expected compile path:

1. Resolve project and output path.
2. Acquire output ownership or return a structured failure.
3. Bind the active compiler provider and record provider identity.
4. Emit compile start after a real handle or provider result exists.
5. Publish diagnostics and output state on finish.
6. Release output ownership only after confirmed terminal result or explicit
   retained-writer handling.
7. Emit compile finish with the provider that owned the run.

Late callbacks from stale generations must not emit successful finish events or
release leases owned by newer work.

## Watch

Expected watch path:

1. Resolve project/output and acquire watch output ownership.
2. Bind the active compiler provider and emit the shared
   `TypstCompileStarted` event with `watch = true`.
3. Parse watch cycles independently from process exit.
4. Emit cycle events for parsed cycle results.
5. Refresh preview/artifact consumers only after a successful cycle and output
   wait policy.
6. Emit watch stop only after confirmed shutdown, retained orphan, or failure is
   recorded.

Process exit after at least one parsed cycle is not itself a compile result.
Every successful built-in or provider-backed watch spawn must emit exactly one
start event before the first cycle, stop, or failure event for that spawn.

## Preview

Expected preview open path:

1. Resolve project and backend.
2. Record `opening=true`, `active=false` for pending opens.
3. Observe the provider/native pending handle using the declared handle style.
4. On successful completion, re-check project key, instance id, generation, and
   prune state.
5. Record active preview and emit opened events only after confirmed open.

Expected stop path:

1. Stop active preview or cancel pending open through the declared cancel style.
2. Report `stopped=true` only after confirmed shutdown.
3. Report pending/superseded cancellation as unconfirmed with `stopped=false`.
4. Keep unconfirmed pending opens observable or retained until they settle.

## Reset

Runtime reset requests stop/cancel from owners, waits within configured bounds,
then records retained or forced state instead of pretending external work was
confirmed stopped. Late provider callbacks after reset are stale unless they
match the live project instance and generation.

Cancellation call style and result normalization are owned by
`typst.core.pending` and should be reused by new async owners. A result may be
reported as confirmed stopped only when the cancel path returns a terminal
confirmation; missing results, pending stops, retained orphans, and missing
explicit receiver styles stay unconfirmed until a later owner-specific result
proves otherwise.
