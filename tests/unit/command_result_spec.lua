local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local command_util = require("typst.ui.commands.util")
local log = require("typst.core.log")

log.clear()

local notifications = {}
local original_notify = vim.notify
rawset(vim, "notify", function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end)

command_util.report_result("TypstUnitNilError", {
    n = 2,
    nil,
    {
        ok = false,
        reason = "no_project",
        message = "No project here",
    },
})

assert(
    #notifications == 1 and notifications[1].message == "No project here",
    "command result handler should notify nil, err failures"
)
assert(
    notifications[1].level == vim.log.levels.WARN,
    "expected no-project command failures should be warnings"
)

notifications = {}
command_util.report_result("TypstUnitOkFalse", {
    n = 1,
    {
        ok = false,
        reason = "missing_output",
        message = "Missing output",
    },
})

assert(
    #notifications == 1 and notifications[1].message == "Missing output",
    "command result handler should notify ok=false payloads"
)

notifications = {}
command_util.report_result("TypstUnitUnknownKey", {
    n = 1,
    {
        ok = false,
        reason = "unknown_project_key",
        message = "Unknown project",
    },
})

assert(
    #notifications == 1 and notifications[1].level == vim.log.levels.ERROR,
    "unknown project key command failures should stay errors"
)

notifications = {}
local result_notifications = {}
local previous_result_notify = command_util.set_result_notify(
    function(message, level)
        result_notifications[#result_notifications + 1] = {
            message = message,
            level = level,
        }
    end
)
command_util.report_result("TypstUnitCustomNotify", {
    n = 1,
    {
        ok = false,
        reason = "custom_notify",
        message = "Custom sink",
    },
})
command_util.set_result_notify(previous_result_notify)
assert(
    #result_notifications == 1
        and result_notifications[1].message == "Custom sink",
    "command result handler should use the registered notify sink"
)
assert(
    #notifications == 0,
    "registered command result notify sink should bypass vim.notify"
)

notifications = {}
local command_notify = command_util.command_notify(function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end)
command_util.create("TypstUnitNotifyOnce", function()
    command_notify("Already notified", vim.log.levels.ERROR)
    return {
        ok = false,
        reason = "already_notified",
        message = "Already notified",
    }
end, command_util.opts("Unit command notification test"))
vim.cmd("TypstUnitNotifyOnce")
assert(
    #notifications == 1,
    "command result handler should not duplicate lower-layer notifications"
)

notifications = {}
command_util.create("TypstUnitInfoThenFailure", function()
    command_notify("Starting command", vim.log.levels.INFO)
    return {
        ok = false,
        reason = "failed_after_info",
        message = "Failed after info",
    }
end, command_util.opts("Unit command info notification test"))
vim.cmd("TypstUnitInfoThenFailure")
assert(
    #notifications == 2,
    "informational command notifications should not suppress failures"
)
assert(
    notifications[2].message == "Failed after info",
    "command wrapper should report failure after an info notification"
)

notifications = {}
command_util.create("TypstUnitPending", function()
    return {
        ok = false,
        pending = true,
        reason = "not_done_yet",
        message = "Operation still pending",
    }
end, command_util.opts("Unit command pending result test"))
vim.cmd("TypstUnitPending")
assert(
    #notifications == 0,
    "pending ok=false command results should not be reported before completion"
)

notifications = {}
command_util.report_result("TypstUnitPendingErr", {
    n = 2,
    nil,
    {
        ok = false,
        pending = true,
        reason = "not_done_yet",
    },
})
assert(
    #notifications == 0,
    "pending nil, err command results should not be reported before completion"
)

notifications = {}
local conceal_commands = require("typst.ui.commands.conceal")
local previous_conceal_notify = command_util.set_result_notify(command_notify)
conceal_commands.register({
    notify = command_notify,
    api = {
        conceal = {
            enable = function()
                return {
                    ok = false,
                    reason = "conceal_failed",
                    message = "Conceal could not start",
                }
            end,
            disable = function()
                return true
            end,
            toggle = function()
                return true
            end,
            refresh = function()
                return true
            end,
            inspect = function()
                return nil
            end,
        },
    },
})
vim.cmd("TypstConcealEnable")
command_util.set_result_notify(previous_conceal_notify)
assert(
    #notifications == 1
        and notifications[1].message == "Conceal could not start",
    "commands should not emit success messages before returning ok=false"
)

notifications = {}
previous_conceal_notify = command_util.set_result_notify(command_notify)
conceal_commands.register({
    notify = command_notify,
    api = {
        conceal = {
            enable = function()
                return nil,
                    {
                        ok = false,
                        reason = "no_project",
                        message = "No conceal project",
                    }
            end,
            disable = function()
                return true
            end,
            toggle = function()
                return true
            end,
            refresh = function()
                return true
            end,
            inspect = function()
                return nil
            end,
        },
    },
})
vim.cmd("TypstConcealEnable")
command_util.set_result_notify(previous_conceal_notify)
assert(
    #notifications == 1 and notifications[1].message == "No conceal project",
    "commands should not emit success messages before returning nil, err"
)

local saw_log = false
for _, entry in ipairs(log.entries()) do
    if entry.message == "command returned failure" then
        saw_log = true
        break
    end
end
assert(saw_log, "structured command failures should be logged")

rawset(vim, "notify", original_notify)
vim.cmd("qa!")
