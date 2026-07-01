local compiler_events = require("typst.compiler.events")
local compiler_service = require("typst.project.services.compiler")
local core_result = require("typst.core.result")
local provider_binding = require("typst.compiler.provider_binding")

local M = {}

-- Provider-neutral compiler/watch state transitions. Built-in and external
-- providers should leave the same project status, last_result, lease state,
-- and User event sequence after a compile/watch/stop result.

---@param result any Raw provider or process result.
---@return TypstCompilerResult result Normalized compiler result.
function M.normalize(result)
    return core_result.normalize_compiler(
        result,
        "Compiler provider returned no result"
    )
end

---@param project TypstProject Project whose compile output should be recorded.
function M.record_compile_output(project)
    local output = (compiler_service.get(project) or {}).output
    if type(output) ~= "string" or output == "" then
        return
    end

    require("typst.workflows.artifacts").record_owned(project, {
        path = output,
        producer = "compile",
    })
end

---@param result any Result candidate.
---@param active_field string? Active compiler service field.
---@return boolean is_cycle True when `result` is an intermediate watch cycle.
function M.is_watch_cycle(result, active_field)
    return active_field == "watcher"
        and type(result) == "table"
        and result.watch == true
        and result.terminal ~= true
        and result.stopped ~= true
        and result.pending ~= true
end

---@param project TypstProject Project whose compiler service is mutated.
---@param result TypstCompilerResult|any Compiler result to apply.
---@param active_field string? Active compiler service field to clear.
function M.apply_status(project, result, active_field)
    result = M.normalize(result)
    if result.stale then
        return
    end

    if M.is_watch_cycle(result, active_field) then
        if result.code == 0 then
            M.record_compile_output(project)
            compiler_service.set(project, {
                last_result = result,
                status = "watching",
                watch_cycle_status = "success",
            })
        else
            compiler_service.set(project, {
                last_result = result,
                status = "watching",
                watch_cycle_status = "error",
            })
        end
        return
    end

    if core_result.is_confirmed_stopped(result) then
        compiler_service.set(project, {
            clear = {
                "process",
                "watcher",
                "process_operation",
                "watcher_operation",
            },
            last_result = result,
            status = "idle",
        })
        provider_binding.clear_if_idle(project)
        return
    end

    if core_result.is_unconfirmed_stop(result) then
        result.status = "stopping_failed"
        result._typst_status_authoritative = true
        compiler_service.set(project, {
            last_result = result,
            status = "stopping_failed",
        })
        return
    end

    local clear = {}
    if result.code == 0 then
        M.record_compile_output(project)
        compiler_service.set(project, {
            last_result = result,
            status = "success",
        })
    else
        compiler_service.set(project, {
            last_result = result,
            status = "error",
        })
    end

    if active_field then
        if active_field == "process" then
            clear = { "process", "process_operation" }
        elseif active_field == "watcher" then
            clear = { "watcher", "watcher_operation" }
        else
            clear = { active_field }
        end
        compiler_service.set(project, { clear = clear })
    end
    provider_binding.clear_if_idle(project)
end

---@param project TypstProject Project for event emission.
---@param result TypstCompilerResult|any Compiler result to emit.
---@param active_field string? Active compiler service field to clear.
function M.emit(project, result, active_field)
    result = M.normalize(result)
    if result.stale then
        return
    end

    M.apply_status(project, result, active_field)

    compiler_events.from_result(project, result)
end

---@param result any Result candidate.
---@return boolean terminal True when this result ends an operation.
function M.terminal(result)
    return core_result.is_terminal(result)
        and not M.is_watch_cycle(result, "watcher")
end

---@param result any Stop result candidate.
---@return boolean restart True when a replacement compile/watch may start.
function M.stop_allows_restart(result)
    return core_result.stop_allows_restart(result)
end

return M
