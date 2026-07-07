local log = require("typst.core.log")

local M = {}

local function project_store()
    return require("typst.project.store")
end

local function compiler()
    return require("typst.resources.drivers.compiler")
end

local function global_operations()
    return require("typst.resources.drivers.global_operations")
end

local function preview()
    return require("typst.resources.drivers.preview")
end

local function project_operations()
    return require("typst.resources.drivers.project_operations")
end

local function toc()
    return require("typst.resources.drivers.toc")
end

local function should_retain_project(ctx, project, retained)
    if not project or (ctx and ctx.force == true) then
        return false
    end
    return retained ~= false
end

local function reset_failed(ctx, summary, project, reason, result, retained)
    summary.ok = false
    local retained_project = should_retain_project(ctx, project, retained)
    if retained_project then
        summary.retain_projects = true
    end
    summary.failed[#summary.failed + 1] = {
        project_key = project and project.key,
        main = project and project.main,
        reason = reason,
        result = result,
        retained = retained_project,
    }
end

local function apply_driver_result(ctx, summary, project, result)
    if type(result) ~= "table" or result.ok ~= false then
        return
    end
    if type(result.failures) == "table" and #result.failures > 0 then
        for _, failure in ipairs(result.failures) do
            local retained = failure.retained
            if retained == nil then
                retained = result.retained
            end
            reset_failed(
                ctx,
                summary,
                project,
                failure.reason or result.reason or "driver_failed",
                failure.result or result.result or result,
                retained
            )
        end
        return
    end
    reset_failed(
        ctx,
        summary,
        project,
        result.reason or "driver_failed",
        result.result or result,
        result.retained
    )
end

local function reset_project(ctx, summary, project)
    project.resetting = true
    local reset_ok, reset_err = xpcall(function()
        toc().close_project(project)
        apply_driver_result(
            ctx,
            summary,
            project,
            preview().stop_project(ctx, project)
        )
        apply_driver_result(
            ctx,
            summary,
            project,
            compiler().stop_project(ctx, project)
        )
        apply_driver_result(
            ctx,
            summary,
            project,
            project_operations().cancel_project(ctx, project)
        )
    end, debug.traceback)
    project.resetting = false
    if not reset_ok then
        log.add("error", "project reset failed", {
            main = project.main,
            error = reset_err,
        })
        reset_failed(
            ctx,
            summary,
            project,
            "project_reset_exception",
            reset_err
        )
    end
end

---Stop live project/global resources during reset.
---@param opts? table Reset controls.
---@return table summary Live-resource reset summary.
function M.reset(opts)
    opts = opts or {}
    local ctx = {
        opts = opts,
        force = opts.force == true,
    }
    local states = vim.tbl_values(project_store().all())
    local summary = {
        ok = true,
        projects = #states,
        failed = {},
    }
    for _, project in ipairs(states) do
        reset_project(ctx, summary, project)
    end

    local global_result = global_operations().cancel_all(ctx)
    summary.global_operations = global_result.result or global_result
    if global_result.ok == false then
        summary.ok = false
        summary.failed[#summary.failed + 1] = {
            reason = global_result.reason or "global_operations_remain",
            result = global_result.result or global_result,
        }
    end

    return summary
end

return M
