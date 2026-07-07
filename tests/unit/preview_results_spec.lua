local results = require("typst.preview.results")

local failed = results.failed("missing_output", "No output")
assert(failed.ok == false, "failed result should set ok=false")
assert(
    failed.reason == "missing_output",
    "failed result should preserve reason"
)
assert(failed.message == "No output", "failed result should preserve message")

local cancelled = results.open_cancelled("restart")
assert(cancelled.ok == true, "cancelled open should be a successful cancel")
assert(cancelled.opened == false, "cancelled open should not claim opened")
assert(cancelled.cancelled == true, "cancelled open should mark cancelled")
assert(cancelled.reason == "restart", "cancelled open should preserve reason")

local stale_reset = results.stale_open({ ok = true, opened = true }, "reset")
assert(stale_reset.ok == false, "stale reset result should set ok=false")
assert(stale_reset.stale == true, "stale reset result should mark stale")
assert(
    stale_reset.reason == "reset",
    "stale reset result should preserve reset reason"
)

local stale_superseded = results.stale_open({}, nil)
assert(
    stale_superseded.reason == "stale_preview_open",
    "stale open without reason should use stale_preview_open"
)

assert(
    results.is_pending({ pending = true }),
    "pending predicate should detect pending handles"
)
assert(results.open_failed(false), "false open result should be failed")
assert(
    results.open_failed({ ok = false }),
    "ok=false open result should be failed"
)
assert(
    results.open_failed({ opened = false }),
    "opened=false result should be failed"
)
assert(results.stop_failed(false), "false stop result should be failed")
assert(
    results.stop_failed({ stopped = false }),
    "stopped=false result should be failed"
)
assert(
    results.stop_failed({ ok = false, stopped = true }),
    "ok=false stopped=true should remain failed without warning metadata"
)
assert(
    not results.stop_failed({
        ok = false,
        stopped = true,
        warning = true,
    }),
    "warning stopped=true stop result should not block cleanup"
)
assert(
    not results.stop_failed({
        ok = false,
        stopped = true,
        backend_stopped = true,
    }),
    "backend-stopped stop result should not block cleanup"
)
assert(
    results.cancel_confirmed({ ok = true, stopped = true }),
    "confirmed cancel should require stopped=true"
)

local compact = results.compact({
    ok = false,
    reason = "x",
    message = "y",
    private = { nested = true },
})
assert(compact.ok == false, "compact should preserve ok")
assert(compact.reason == "x", "compact should preserve reason")
assert(compact.private == nil, "compact should omit arbitrary nested fields")
