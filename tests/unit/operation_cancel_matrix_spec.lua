local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operations = require("typst.project.services.operations")
local project_services = require("typst.project.services")

local project = {
    key = "operation-cancel-matrix",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    services = project_services.new_state(),
}

local function outcome(summary, record)
    for _, item in ipairs(summary.outcomes or {}) do
        if item.id == record.id then
            return item
        end
    end
end

local cancelled = assert(operations.begin(project, "export"))
cancelled.handle = {
    cancel = function()
        return true, { stopped = true, reason = "user_cancelled" }
    end,
}
local cancelled_summary = operations.cancel_project(project, { skip = {} })
assert(
    cancelled_summary.cancelled == 1 and cancelled_summary.failed == 0,
    "successful operation cancellation should be counted as cancelled"
)
assert(
    outcome(cancelled_summary, cancelled).outcome == "cancelled",
    "successful operation cancellation should expose a cancelled outcome"
)
assert(
    project.services.operations.active_by_id[cancelled.id] == nil,
    "successfully cancelled operations should leave active records"
)

local dot_cancelled = assert(operations.begin(project, "export"))
local dot_received_reason = nil
dot_cancelled.handle = {
    cancel_style = "dot",
    cancel = function(opts)
        dot_received_reason = opts and opts.reason
        return true, { stopped = true, reason = "dot_cancelled" }
    end,
}
local dot_summary = operations.cancel_project(project, {
    skip = {},
    reason = "dot_stop",
})
assert(
    dot_summary.cancelled == 1 and dot_received_reason == "dot_stop",
    "dot-style operation cancellation should receive cancel opts directly"
)
assert(
    outcome(dot_summary, dot_cancelled).outcome == "cancelled",
    "dot-style operation cancellation should expose a cancelled outcome"
)

local dot_unknown = assert(operations.begin(project, "export"))
dot_unknown.handle = {
    cancel = function(opts)
        if opts and opts.reason == "dot_unknown_stop" then
            return true, { stopped = true, reason = "dot_unknown_cancelled" }
        end
        return false, { reason = "missing_reason" }
    end,
}
local dot_unknown_summary = operations.cancel_project(project, {
    skip = {},
    reason = "dot_unknown_stop",
})
assert(
    dot_unknown_summary.cancelled == 1,
    "unknown dot-style operation cancellation should infer direct option calls"
)
assert(
    outcome(dot_unknown_summary, dot_unknown).reason == "dot_unknown_cancelled",
    "unknown dot-style operation cancellation should preserve the fallback result"
)

local colon_cancelled = assert(operations.begin(project, "export"))
local colon_handle = { pending = true, cancelled = false }
function colon_handle:cancel(opts)
    if self ~= colon_handle then
        return true, { stopped = true, reason = "wrong_receiver" }
    end
    self.cancelled = opts and opts.reason == "colon_stop"
    return true, { stopped = true, reason = "colon_cancelled" }
end
colon_cancelled.handle = colon_handle
local colon_summary = operations.cancel_project(project, {
    skip = {},
    reason = "colon_stop",
})
assert(
    colon_summary.cancelled == 1 and colon_handle.cancelled == true,
    "colon-style operation cancellation should receive the handle as self"
)
assert(
    outcome(colon_summary, colon_cancelled).reason == "colon_cancelled",
    "colon-style operation cancellation should preserve the handle result"
)

local retained = assert(operations.begin(project, "render"))
retained.handle = {
    operation = {
        state = "orphaned-retained",
        result = { orphaned = true, reason = "still_running" },
        cancel = function()
            return false, { orphaned = true, reason = "still_running" }
        end,
        wait = function() end,
    },
}
local retained_summary = operations.cancel_project(project, { skip = {} })
assert(
    retained_summary.retained == 1 and retained_summary.failed == 0,
    "orphaned operations should be counted as retained"
)
assert(
    outcome(retained_summary, retained).outcome == "retained",
    "orphaned operations should expose a retained outcome"
)
assert(
    project.services.operations.active_by_id[retained.id] == nil
        and project.services.operations.retained_by_id[retained.id]
            == retained,
    "retained orphan operations should move from active to retained"
)
operations.finish(project, retained, {
    ok = false,
    was_orphaned = true,
    exited_after_orphan = true,
})

local uncancellable = assert(operations.begin(project, "profile"))
uncancellable.handle = { pending = true, raw = true }
local uncancellable_summary = operations.cancel_project(project, { skip = {} })
assert(
    uncancellable_summary.uncancellable == 1
        and uncancellable_summary.retained == 1,
    "unsupported live handles should be counted as uncancellable retained work"
)
assert(
    outcome(uncancellable_summary, uncancellable).outcome == "uncancellable",
    "unsupported live handles should expose an uncancellable outcome"
)
assert(
    project.services.operations.retained_by_id[uncancellable.id]
        == uncancellable,
    "unsupported live handles should remain visible as retained records"
)
operations.finish(project, uncancellable, {
    ok = false,
    reason = "force_cleared",
})

local failed = assert(operations.begin(project, "test"))
failed.handle = {
    cancel = function()
        return false, { reason = "cancel_failed" }
    end,
}
local failed_summary = operations.cancel_project(project, { skip = {} })
assert(
    failed_summary.failed == 1 and failed_summary.retained == 0,
    "failed cancellation should be counted as failed without retention"
)
assert(
    outcome(failed_summary, failed).outcome == "failed",
    "failed cancellation should expose a failed outcome"
)
assert(
    project.services.operations.active_by_id[failed.id] == failed,
    "failed cancellation should leave the active record visible"
)
operations.clear(project, failed)

local stale = assert(operations.begin(project, "coverage"))
stale.handle = false
local stale_summary = operations.cancel_project(project, { skip = {} })
assert(
    stale_summary.stale == 1 and stale_summary.failed == 0,
    "dead operation records should be counted as stale"
)
assert(
    outcome(stale_summary, stale).outcome == "stale",
    "dead operation records should expose a stale outcome"
)
assert(
    project.services.operations.active_by_id[stale.id] == nil,
    "stale operation records should be cleared"
)

vim.cmd("qa!")
