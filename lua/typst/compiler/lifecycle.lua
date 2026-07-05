local compiler_events = require("typst.compiler.events")
local restart_handle = require("typst.core.restart_handle")
local compiler_result = require("typst.compiler.state_machine")

local M = {}

--- Invoke a compiler provider while preserving started-before-terminal events.
---
--- Providers are allowed to complete synchronously. Buffer those terminal
--- results until after the started event so user autocmds always observe a
--- stable started -> terminal order. By the time `TypstCompileStarted` is
--- emitted, project compiler state must already expose the active handle or
--- operation, or an explicit startup-failure state.
---@param project table Project state whose compiler service owns the run.
---@param callback? fun(result:TypstCompilerResult)
---@param invoke fun(callback:fun(result:TypstCompilerResult)):unknown
---@param started_status string Status exposed in the started event payload.
---@param opts? table Lifecycle hooks and active-field metadata.
---@return unknown handle Provider-specific handle returned by `invoke`.
function M.with_started_event(project, callback, invoke, started_status, opts)
    opts = opts or {}
    local pending = {}
    local invoking = true

    local function wrapped(result)
        result = compiler_result.normalize(result)
        if invoking then
            pending[#pending + 1] = result
            return
        end

        if opts.on_terminal then
            opts.on_terminal(result)
        end
        compiler_result.emit(project, result, opts.active_field)
        if callback then
            callback(result)
        end
    end

    local handle = invoke(wrapped)
    invoking = false

    if opts.after_started then
        opts.after_started(handle, pending)
    end
    compiler_events.started(project, { status = started_status })
    for _, result in ipairs(pending) do
        result = compiler_result.normalize(result)
        if opts.on_terminal then
            opts.on_terminal(result)
        end
        compiler_result.emit(project, result, opts.active_field)
        if callback then
            callback(result)
        end
    end

    return handle
end

--- Stop an active compiler resource and start its replacement when allowed.
---
--- Idle/no-active stop results are treated as safe for restart. Explicit
--- provider failures block the replacement and finish the restart handle with
--- the stop payload.
---@param stop_active fun(callback:fun(result:TypstCompilerResult)):unknown
---@param start_next fun(callback:fun(result:TypstCompilerResult)):unknown
---@param callback? fun(result:TypstCompilerResult)
---@return table restart Restart handle tracking stop and replacement handles.
function M.replace_active(stop_active, start_next, callback)
    local restart = restart_handle.new()
    local stop_handle = stop_active(function(result)
        if restart.result ~= nil or restart.cancel_requested then
            return
        end
        if compiler_result.stop_allows_restart(result) then
            local next_handle = start_next(function(next_result)
                restart:finish(next_result)
                if callback then
                    callback(next_result)
                end
            end)
            restart:set_next_handle(next_handle)
        elseif callback then
            restart:finish(result)
            callback(result)
        else
            restart:finish(result)
        end
    end)
    restart:set_stop_handle(stop_handle)
    return restart
end

return M
