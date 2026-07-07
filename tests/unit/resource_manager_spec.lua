local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local manager = require("typst.runtime.resource_manager")
local typst = require("typst")

assert(type(manager.reset) == "function", "resource manager should reset")
assert(type(manager.snapshot) == "function", "resource manager should snapshot")
assert(
    type(manager.stop_live_resources) == "function",
    "resource manager should expose live-resource stop driver"
)

local before_epoch = manager.epoch()
local reset = typst.reset({ force = true })
assert(type(reset) == "table", "typst.reset should return a summary")
assert(
    reset.epoch == before_epoch + 1,
    "typst.reset should advance the resource-manager epoch"
)
assert(
    manager.epoch() == reset.epoch,
    "manager epoch should match reset summary"
)
assert(not manager.in_reset(), "manager should leave reset state idle")
assert(
    manager.last_reset() == reset,
    "manager should retain the latest reset summary"
)
assert(
    type(reset.reset_manifest) == "table",
    "manager reset should include manifest summary"
)
assert(
    type(reset.final_snapshot) == "table",
    "manager reset should include final resource snapshot"
)

local snapshot = manager.snapshot()
assert(snapshot.epoch == manager.epoch(), "snapshot should include epoch")
assert(
    type(snapshot.projects) == "table",
    "snapshot should include project table"
)
assert(type(snapshot.global) == "table", "snapshot should include globals")
assert(
    type(snapshot.global.operations) == "table",
    "snapshot should include global operations"
)
assert(
    type(snapshot.global.deferred) == "table",
    "snapshot should include deferred queue state"
)
assert(
    type(snapshot.blockers) == "table",
    "snapshot should include blocker list"
)

local token = manager.token(nil, "resource-manager-spec")
local valid, reason = manager.valid_token(token)
assert(valid == true and reason == nil, "fresh token should be valid")

typst.reset({ force = true })
local stale, stale_reason = manager.valid_token(token)
assert(stale == false, "token should become stale after reset")
assert(stale_reason == "reset", "stale token reason should be reset")

local original_execute_manifest = manager.execute_manifest
local original_log = package.loaded["typst.core.log"]
package.loaded["typst.core.log"] = {
    add = function()
        error("synthetic log add failure")
    end,
    clear = function()
        error("synthetic log clear failure")
    end,
}
manager.execute_manifest = function()
    return {
        retain_projects = true,
        stop_resources = {
            ok = false,
            projects = 0,
            failed = {},
        },
        _phase_order = {},
    }
end
local retained_with_bad_log = manager.reset({ force = false })
assert(
    retained_with_bad_log.retained_projects == true,
    "reset should still report retained projects when logging fails"
)
assert(
    not manager.in_reset(),
    "manager should end reset context when retain logging fails"
)
manager.execute_manifest = function()
    return {
        retain_projects = false,
        stop_resources = {
            ok = true,
            projects = 0,
            failed = {},
        },
        _phase_order = {},
    }
end
local clear_with_bad_log = manager.reset({ force = true })
assert(
    clear_with_bad_log.ok == true,
    "reset should still complete when log clearing fails"
)
assert(
    not manager.in_reset(),
    "manager should end reset context when log clearing fails"
)
package.loaded["typst.core.log"] = original_log

local manifest = require("typst.runtime.resource_manifest")
local original_summary = manifest.summary
manifest.summary = function()
    error("synthetic reset summary failure")
end
manager.execute_manifest = function()
    return {
        retain_projects = false,
        stop_resources = {
            ok = true,
            projects = 0,
            failed = {},
        },
        _phase_order = {},
    }
end
local summary_failure = manager.reset({ force = true })
manifest.summary = original_summary
manager.execute_manifest = original_execute_manifest
assert(
    summary_failure.ok == false
        and summary_failure.reason == "resource_manager_reset_exception",
    "reset should return a structured summary when reset reporting fails"
)
assert(
    not manager.in_reset(),
    "manager should end reset context when reset reporting fails"
)

vim.cmd("qa!")
