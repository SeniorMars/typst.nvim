local base = require("typst.project.services.base")

local M = {}

---@return TypstProjectCompilerService service Default compiler service table.
function M.defaults()
    return {
        status = "idle",
        generation = 0,
        watch_generation = 0,
        watch_cycle_generation = 0,
    }
end

---@param service TypstProjectCompilerService Compiler service table to normalize.
---@return TypstProjectCompilerService service Normalized compiler service table.
local function normalize(service)
    service.status = service.status or "idle"
    service.generation = service.generation or 0
    service.watch_generation = service.watch_generation or 0
    service.watch_cycle_generation = service.watch_cycle_generation or 0
    return service
end

---@param project TypstProject? Project whose compiler service is read.
---@return TypstProjectCompilerService? service Compiler service table, if present.
function M.get(project)
    if type(project) ~= "table" or type(project.services) ~= "table" then
        return nil
    end
    local service = project.services.compiler
    if type(service) ~= "table" then
        return nil
    end
    return normalize(service)
end

---@param project TypstProject Project whose compiler service is ensured.
---@return TypstProjectCompilerService service Compiler service table.
function M.ensure(project)
    local service = base.service(project, "compiler")
    if not service then
        error("typst.nvim: compiler service requires a project", 2)
    end
    return normalize(service)
end

---@param project TypstProject Project whose compiler service is mutated.
---@param fields TypstProjectCompilerServicePatch Fields to set; `clear`/`_clear` removes keys first.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.set(project, fields)
    local compiler = assert(base.update(project, "compiler", fields))
    return normalize(compiler)
end

local function merge(fields, defaults)
    return vim.tbl_extend("force", defaults or {}, fields or {})
end

local function result_status(result, success_status, failure_status)
    if type(result) == "table" and result._typst_status_authoritative then
        return result.status
    end
    return type(result) == "table" and result.code == 0 and success_status
        or failure_status
end

---Start a one-shot compile transition.
---@param project TypstProject Project whose compiler service is mutated.
---@param fields? TypstProjectCompilerServicePatch Additional fields to store.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.start_compile(project, fields)
    local compiler = M.ensure(project)
    local generation = fields and fields.generation
        or ((compiler and compiler.generation) or 0) + 1
    return M.set(
        project,
        merge(fields, {
            generation = generation,
            status = "compiling",
        })
    )
end

---Finish a one-shot compile transition.
---@param project TypstProject Project whose compiler service is mutated.
---@param result TypstCompilerResult Compile terminal result.
---@param opts? {clear_active?:boolean} Transition controls.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.finish_compile(project, result, opts)
    opts = opts or {}
    local clear = opts.clear_active == false and nil
        or {
            "process",
            "process_operation",
            "active_compile_deps_path",
        }
    return M.set(project, {
        clear = clear,
        last_result = result,
        status = result_status(result, "success", "error"),
    })
end

---Start a long-running watch transition.
---@param project TypstProject Project whose compiler service is mutated.
---@param fields? TypstProjectCompilerServicePatch Additional fields to store.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.start_watch(project, fields)
    local compiler = M.ensure(project)
    local generation = fields and fields.watch_generation
        or ((compiler and compiler.watch_generation) or 0) + 1
    return M.set(
        project,
        merge(fields, {
            watch_generation = generation,
            status = "starting",
        })
    )
end

---Record an intermediate watch compile cycle.
---@param project TypstProject Project whose compiler service is mutated.
---@param result TypstCompilerResult Watch cycle result.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.finish_watch_cycle(project, result)
    return M.set(project, {
        last_result = result,
        status = "watching",
        watch_cycle_status = type(result) == "table"
                and result.code == 0
                and "success"
            or "error",
    })
end

---Finish a long-running watch process.
---@param project TypstProject Project whose compiler service is mutated.
---@param result TypstCompilerResult Watch terminal result.
---@param opts? {status?:string, clear_active?:boolean} Transition controls.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.finish_watch_process(project, result, opts)
    opts = opts or {}
    local status = opts.status or result_status(result, "success", "error")
    local clear = opts.clear_active == false and nil
        or {
            "watcher",
            "watcher_operation",
        }
    return M.set(project, {
        clear = clear,
        last_result = result,
        status = status,
    })
end

---Begin a stop transition for active compiler work.
---@param project TypstProject Project whose compiler service is mutated.
---@param fields? TypstProjectCompilerServicePatch Additional fields to store.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.begin_stop(project, fields)
    return M.set(project, merge(fields, { status = "stopping" }))
end

---Finish a confirmed stop transition.
---
---Output leases are intentionally not cleared here. Callers must release output
---ownership before recording a confirmed stop, so release failures stay visible.
---@param project TypstProject Project whose compiler service is mutated.
---@param result TypstCompilerResult Stop result.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.finish_stop_confirmed(project, result)
    return M.set(project, {
        clear = {
            "process",
            "watcher",
            "stopping_compile",
            "process_operation",
            "watcher_operation",
        },
        last_result = result,
        status = "idle",
    })
end

---Finish an unconfirmed stop transition.
---@param project TypstProject Project whose compiler service is mutated.
---@param result TypstCompilerResult Stop result.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.finish_stop_unconfirmed(project, result)
    if type(result) == "table" then
        result._typst_unconfirmed_stop = true
        result.status = "stopping_failed"
        result._typst_status_authoritative = true
    end
    return M.set(project, {
        last_result = result,
        status = "stopping_failed",
    })
end

---Force-clear retained compiler state without claiming external shutdown.
---@param project TypstProject Project whose compiler service is mutated.
---@param result TypstCompilerResult Force-clear result.
---@return TypstProjectCompilerService compiler Compiler service table.
function M.force_clear(project, result)
    return M.set(project, {
        clear = {
            "process",
            "watcher",
            "stopping_compile",
            "output_lease",
            "process_operation",
            "watcher_operation",
        },
        status = "idle",
        last_result = result,
    })
end

---@param service TypstProjectCompilerService? Compiler service table.
---@return boolean active True when a compile/watch/stop handle is active.
function M.has_active(service)
    service = service or {}
    return service.process ~= nil
        or service.watcher ~= nil
        or service.stopping_compile ~= nil
end

---@param project TypstProject Project to snapshot.
---@return table? snapshot Summary-safe compiler service snapshot.
function M.snapshot(project)
    local compiler = M.get(project)
    if not compiler then
        return nil
    end
    return {
        status = compiler.status,
        generation = compiler.generation,
        watch_generation = compiler.watch_generation,
        watch_cycle_generation = compiler.watch_cycle_generation,
        has_process = compiler.process ~= nil,
        has_watcher = compiler.watcher ~= nil,
        stopping = compiler.stopping_compile ~= nil,
        last_cwd = compiler.last_cwd,
        last_profile = compiler.last_profile,
        provider_label = compiler.provider_label,
        last_provider_label = compiler.last_provider_label,
        provider_builtin = compiler.provider_builtin,
        provider_external = compiler.provider_external,
        output = compiler.output,
    }
end

return M
