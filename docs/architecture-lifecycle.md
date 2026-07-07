# typst.nvim Lifecycle Architecture

This document records lifecycle ownership rules that must stay true while the
plugin moves from early reset to a stable core. It is a maintainer contract, not
a user tutorial.

## Project State

```text
unattached
  -> resolving
  -> attached
  -> resolution_pending(import_scan)
  -> import_scan_suggested
  -> reassigning(command lookup)
  -> detaching
  -> resource_stopping
  -> pruned
  -> retained_due_to_active_resource
```

### Project Invariants

- A buffer belongs to at most one live project key.
- Project keys are derived from canonical `(root, main)` path identity.
- Public project methods return copied snapshots, not live service tables.
- Deferred import-scan callbacks must check buffer validity, buffer path,
  config generation, and expected project key before mutating state. They may
  record a suggested main, but they must not reassign a buffer in the
  background; command-time project lookup owns accepting a suggestion.
- A project with no buffers may remain registered only while active resources
  are stopping, retained, or explicitly force-clearable.
- Project prune must happen at most once for a project instance.

## Compiler State

```text
idle
  -> compiling
  -> stopping
  -> success/error
  -> idle

idle
  -> starting_watch
  -> watching
  -> stopping
  -> idle/error/stopping_failed
```

### Compiler Invariants

- A project may have at most one compile/watch owner.
- Every compile/watch result carries a generation; stale generations cannot
  publish diagnostics, update output state, refresh preview, or report success
  as current.
- Every confirmed stop releases output ownership before recording stopped.
- An unconfirmed stop retains enough compiler state for force-clear recovery.
- Scratch projects use synthetic main paths for identity only; the built-in CLI
  provider must reject normal file-backed compile/watch until the buffer is
  saved. Stdin-backed fragment compiles are allowed because the compiler input
  is `-`, not the synthetic scratch path.

## Preview State

```text
inactive
  -> opening
  -> active
  -> refreshing
  -> stopping
  -> inactive

active
  -> stopping_failed
  -> force_clear/recover
```

### Preview Invariants

- `active=true` means a backend confirmed open.
- Pending callback opens use `opening=true`, not `active=true`.
- Stop, restart, and forced cleanup must cancel or clear pending opens so a late
  provider callback cannot resurrect preview state.
- Pending stop keeps active state until the backend confirms stopped.
- Restart of an active preview must wait for stop success or return a structured
  failure. Restart of a pending open may optimistically supersede the old open;
  that old open is recorded as `superseded=true`, `stopped=false`, and
  `cancel_pending=true` when provider cancellation is still settling. The
  superseded handle is retained until the provider result settles.
- Native browser follow-buffer transfers exactly one route from the old project
  to the new project.

## Diagnostics State

```text
clear(source)
  -> parse/publish(source)
  -> owned_namespaces_by_project
  -> clear(source|project|all)
```

### Diagnostics Invariants

- Diagnostic sources have separate namespaces so one source cannot erase
  another source by accident.
- Parser-created hidden buffers are capped per publish.
- Providers that return native `by_buffer` diagnostics must supply existing
  buffer numbers; those buffers are not path-expanded by the parser.
- Quickfix and loclist clear operations must preserve user-replaced lists.

## Cache Invalidation Map

| Owner | Invalidated by |
| --- | --- |
| Project index | buffer writes, project graph changes, config generation |
| Import scan | root/main/config changes, cache clear |
| Source maps | output stat, config generation, source changedtick or file stat |
| Completion LSP cache | changedtick, request generation, reset |
| Path completion | directory TTL, config generation, reset |
| Conceal chunks | Tree-sitter parser callbacks, bytes changes, reset |
| Diagnostics buffers | source clear, project clear, reset |
| Preview exports | newer export generation, preview cleanup, reset |

## Async Callback Rule

Every scheduled or pending callback that mutates state must check the relevant
liveness token before applying a result:

- project key and instance id still match;
- buffer is still valid and still has the expected path;
- config generation still matches when resolution/config affected the work;
- changedtick still matches when applying editor-facing results;
- operation/result has not already finished;
- provider result is not stale after a newer generation or replacement.

The stability gate should prefer tests that prove these invariants over tests
that only assert a happy-path command returns.
