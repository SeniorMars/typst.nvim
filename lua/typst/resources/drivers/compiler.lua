local compiler_service = require("typst.project.services.compiler")
local core_result = require("typst.core.result")
local log = require("typst.core.log")

local M = {}

local function compiler_module()
    return require("typst.compiler")
end

local function clear_lifecycle_compile_handle(project)
    local compiler_state = compiler_service.get(project) or {}
    if project and compiler_state.stopping_compile then
        compiler_service.set(project, {
            clear = { "process", "active_compile_deps_path" },
            status = "idle",
        })
    end
end

---Stop compiler/watch resources for a project during reset.
---@param ctx table Reset driver context.
---@param project table Project state.
---@return table result Stop summary.
function M.stop_project(ctx, project)
    ctx = ctx or {}
    local opts = ctx.opts or {}
    local compiler_state = compiler_service.get(project) or {}
    if
        not (
            compiler_state.process
            or compiler_state.watcher
            or compiler_state.stopping_compile
        )
    then
        compiler_service.set(project, {
            clear = { "process", "watcher" },
            status = "idle",
        })
        return {
            ok = true,
            result = {
                code = 0,
                stopped = true,
                idle = true,
            },
        }
    end

    local done = false
    local result = nil
    local ok, err = pcall(compiler_module().stop, project, function(stop_result)
        result = stop_result
        done = true
    end)
    if not ok then
        log.add("warn", "failed to stop compiler during reset", {
            main = project.main,
            error = err,
        })
        result = {
            code = 1,
            stopped = false,
            error = err,
        }
        done = true
    end

    if not done then
        local timeout_ms = opts.timeout_ms or 1500
        vim.wait(timeout_ms, function()
            return done
        end, 10, false)
        if not done then
            log.add(
                "warn",
                "compiler stop timed out during reset; forcing shutdown",
                {
                    main = project.main,
                    timeout_ms = timeout_ms,
                }
            )
            local forced_ok, forced_result =
                pcall(compiler_module().stop_for_exit, project, {
                    timeout_ms = opts.force_timeout_ms or 250,
                    kill_timeout_ms = opts.force_kill_timeout_ms or 250,
                })
            result = forced_ok and forced_result
                or {
                    code = 1,
                    stopped = false,
                    error = forced_result,
                }
            done = true
        end
    end

    if core_result.is_confirmed_stopped(result) then
        clear_lifecycle_compile_handle(project)
        compiler_service.set(project, {
            clear = { "process", "watcher", "stopping_compile" },
            status = "idle",
        })
        return {
            ok = true,
            result = result,
        }
    end

    compiler_service.set(project, { status = "stopping_failed" })
    log.add("error", "retaining compiler resources after reset stop failed", {
        main = project.main,
        result = result,
    })
    return {
        ok = false,
        reason = "compiler_stop_failed",
        result = result,
    }
end

return M
