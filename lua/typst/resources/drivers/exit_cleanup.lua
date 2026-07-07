local events = require("typst.core.events")
local log = require("typst.core.log")
local preview_service = require("typst.project.services.preview")
local project_operations = require("typst.project.services.operations")

local M = {}

local function compiler_module()
    return require("typst.compiler")
end

local function preview_module()
    return require("typst.preview.controller")
end

local function project_store()
    return require("typst.project.store")
end

local function safe_tostring(value)
    local ok, text = pcall(tostring, value)
    if ok then
        return text
    end
    return "<tostring failed>"
end

local function safe_summary_value(value, depth, seen)
    local value_type = type(value)
    if
        value == nil
        or value_type == "boolean"
        or value_type == "number"
        or value_type == "string"
    then
        return value
    end
    if value_type ~= "table" then
        return safe_tostring(value)
    end

    depth = depth or 0
    if depth >= 4 then
        return "<max-depth>"
    end
    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true

    local out = {}
    local count = 0
    local ok, iter, state, first = pcall(pairs, value)
    if not ok then
        seen[value] = nil
        return safe_tostring(value)
    end
    while true do
        local next_ok, key, item = pcall(iter, state, first)
        if not next_ok then
            out["<iteration_error>"] = safe_tostring(key)
            break
        end
        if key == nil then
            break
        end
        first = key
        count = count + 1
        if count > 32 then
            out["<truncated>"] = true
            break
        end
        local safe_key = safe_summary_value(key, depth + 1, seen)
        if type(safe_key) ~= "string" and type(safe_key) ~= "number" then
            safe_key = safe_tostring(safe_key)
        end
        out[safe_key] = safe_summary_value(item, depth + 1, seen)
    end
    seen[value] = nil
    return out
end

local function record_exit_failure(summary, project, reason, err, level)
    summary.ok = false
    local failure = {
        main = project and project.main or nil,
        reason = reason,
        error = safe_tostring(err),
    }
    if type(err) == "table" then
        failure.result = safe_summary_value(err)
    end
    summary.failed[#summary.failed + 1] = failure
    log.add(level or "error", "project exit cleanup failed", {
        main = project and project.main or nil,
        reason = reason,
        error = err,
    })
end

local function preview_exit_failure_reason(result)
    if type(result) == "table" then
        if result.pending == true then
            return "preview_stop_pending"
        end
        if result.ok == false then
            return "preview_stop_failed"
        end
    elseif result == false then
        return "preview_stop_declined"
    end
    return nil
end

local function preview_live(project)
    local preview = preview_service.get(project) or {}
    return preview.active == true
        or preview.opening == true
        or preview.stopping == true
end

local function stop_project_for_exit(project, summary)
    if preview_live(project) then
        local ok, preview_result = pcall(function()
            return preview_module().stop_for_exit(project, {
                lifecycle = true,
                reason = "exit",
            })
        end)
        if not ok then
            record_exit_failure(
                summary,
                project,
                "preview_stop_error",
                preview_result,
                "warn"
            )
            local cleared, clear_err = pcall(function()
                return preview_module().clear_state(project, {
                    lifecycle = true,
                    reason = "exit",
                })
            end)
            if not cleared then
                record_exit_failure(
                    summary,
                    project,
                    "preview_clear_error",
                    clear_err,
                    "warn"
                )
            end
        else
            local reason = preview_exit_failure_reason(preview_result)
            if reason then
                record_exit_failure(
                    summary,
                    project,
                    reason,
                    preview_result,
                    "warn"
                )
            end
        end
    end

    local compiler_ok, compiler_result = pcall(function()
        return compiler_module().stop_for_exit(project)
    end)
    if not compiler_ok then
        record_exit_failure(
            summary,
            project,
            "compiler_stop_error",
            compiler_result
        )
    end

    local cancelled_ok, cancelled =
        pcall(project_operations.cancel_project, project, {
            reason = "exit",
            timeout_ms = 100,
            kill_timeout_ms = 100,
            wait_timeout_ms = 250,
        })
    if not cancelled_ok then
        record_exit_failure(
            summary,
            project,
            "operation_cancel_error",
            cancelled
        )
        return
    end
    if
        type(cancelled) == "table"
        and ((cancelled.failed or 0) > 0 or (cancelled.retained or 0) > 0)
    then
        log.add("warn", "project operations remained during exit", {
            main = project.main,
            summary = cancelled,
        })
        summary.ok = false
        summary.failed[#summary.failed + 1] = {
            main = project.main,
            reason = "operation_cancel_incomplete",
            result = safe_summary_value(cancelled),
        }
    end
end

---Stop project resources before Neovim exits.
---@param _opts? table Exit controls.
---@return table summary Exit cleanup summary.
function M.stop_for_exit_all(_opts)
    local states = project_store().all()
    local summary = {
        ok = true,
        projects = vim.tbl_count(states),
        failed = {},
    }
    events.emit_global("TypstEventQuit", {
        projects = vim.tbl_count(states),
    })
    for _, project in pairs(states) do
        local ok, err = xpcall(function()
            stop_project_for_exit(project, summary)
        end, debug.traceback)
        if not ok then
            record_exit_failure(summary, project, "project_exit_error", err)
        end
    end
    return summary
end

return M
