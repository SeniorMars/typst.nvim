local log = require("typst.core.log")
local notify_user = require("typst.core.notify").user
local util = require("typst.core.util")

local M = {}

local function viewer_module()
    return require("typst.viewer")
end

local function preview_module()
    return require("typst.integrations.typst_preview")
end

local function protected(action, project, callback)
    local ok, result = xpcall(callback, debug.traceback)
    if ok then
        return result
    end

    local failure = {
        ok = false,
        reason = "consumer_error",
        action = action,
        message = ("Typst post-build %s failed"):format(action),
        error = result,
    }
    log.add("warn", failure.message, {
        main = project and project.main or nil,
        error = result,
    })
    return failure
end

local function consumer_opts(opts)
    opts = opts or {}
    return {
        source = opts.source,
        watch = opts.watch == true,
        profile = opts.profile,
        cycle = opts.cycle,
        cycle_generation = opts.cycle_generation,
    }
end

local function should_consume(result)
    return type(result) == "table"
        and result.stale ~= true
        and result.stopped ~= true
        and result.pending ~= true
end

local result_fields = {
    "ok",
    "code",
    "stdout",
    "stderr",
    "stale",
    "stopped",
    "idle",
    "reason",
    "message",
    "active_output",
    "deps_path",
    "watch",
    "cycle",
    "generation",
    "watch_generation",
    "cycle_generation",
}

local function result_snapshot(result)
    local snapshot = {}
    for _, key in ipairs(result_fields) do
        if result[key] ~= nil then
            snapshot[key] = result[key]
        end
    end
    return snapshot
end

local function notify_reload(project, result, opts)
    local reload_opts = consumer_opts(opts)
    return {
        viewer = protected("viewer reload", project, function()
            return viewer_module().reload(
                project,
                result_snapshot(result),
                reload_opts
            )
        end),
        preview = protected("preview refresh", project, function()
            return preview_module().refresh(
                project,
                result_snapshot(result),
                reload_opts
            )
        end),
    }
end

local function open_viewer(project, notify)
    return protected("viewer open", project, function()
        local path = viewer_module().open(project)
        if path ~= false then
            notify_user(
                notify,
                ("Opened %s"):format(util.relpath(path, project.root))
            )
        end
        return path
    end)
end

--- Notify viewer/preview consumers after a one-shot compile result.
---@param project table Project state whose output may have changed.
---@param result table Compile result.
---@param opts? table Consumer options.
---@param notify? fun(message:string, level?:integer) Notification sink.
---@return table summary Consumer action results.
function M.after_compile(project, result, opts, notify)
    opts = opts or {}
    local summary = {
        source = "compile",
        notified = false,
        opened = false,
    }
    if not should_consume(result) or result.code ~= 0 then
        summary.skipped = true
        return summary
    end

    summary.notified = notify_reload(
        project,
        result,
        vim.tbl_extend("force", opts, { source = "compile" })
    )
    if opts.open == true then
        summary.opened = open_viewer(project, notify)
    end
    return summary
end

--- Notify viewer/preview consumers after a watch compile cycle.
---@param project table Project state whose output may have changed.
---@param result table Watch-cycle result.
---@param opts? table Consumer options.
---@param notify? fun(message:string, level?:integer) Notification sink.
---@return table summary Consumer action results.
function M.after_watch_cycle(project, result, opts, notify)
    opts = opts or {}
    local summary = {
        source = "watch",
        notified = false,
        opened = false,
    }
    if not should_consume(result) then
        summary.skipped = true
        return summary
    end

    if opts.open == true and result.code == 0 then
        summary.opened = open_viewer(project, notify)
    end

    summary.notified = notify_reload(
        project,
        result,
        vim.tbl_extend("force", opts, {
            source = "watch",
            watch = true,
            cycle = result.cycle,
            cycle_generation = result.cycle_generation,
        })
    )
    return summary
end

return M
