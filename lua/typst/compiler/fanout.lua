local compiler_dependencies = require("typst.compiler.dependencies")
local compiler_events = require("typst.compiler.events")
local diagnostics = require("typst.diagnostics")
local log = require("typst.core.log")

local M = {}

-- Compiler fanout centralizes compiler-state post-result consumers. Compile/watch
-- controllers update compiler service state, then call this module for artifact
-- ownership, diagnostics, dependency graph, logs, and compiler events.
-- Viewer/preview refresh routes through compiler.consumers from API/controller
-- paths.

local function compiler_output(project)
    return (require("typst.project.services.compiler").get(project) or {}).output
end

local function record_compile_output(project, opts)
    opts = opts or {}
    local output = opts.output or compiler_output(project)
    if type(output) ~= "string" or output == "" then
        return
    end

    require("typst.workflows.artifacts").record_owned(project, {
        path = output,
        producer = opts.producer or "compile",
        generation = opts.generation,
    })
end

local function diagnostic_text(result)
    return ("%s\n%s"):format(result.stderr or "", result.stdout or "")
end

local function clear_compiler_diagnostics(project)
    diagnostics.clear(project, { source = "compiler" })
end

function M.record_compile_output(project, opts)
    return record_compile_output(project, opts)
end

function M.compile_succeeded(project, result, opts)
    opts = opts or {}
    local deps_path = opts.deps_path or (result and result.deps_path)
    record_compile_output(project, {
        output = opts.output,
        generation = opts.generation,
        producer = "compile",
    })
    clear_compiler_diagnostics(project)
    compiler_dependencies.update_project(
        project,
        compiler_dependencies.take(deps_path, project.root)
    )
    log.add("info", "compile succeeded", { output = opts.output })
    compiler_events.succeeded(project, result)
end

function M.compile_failed(project, result, opts)
    opts = opts or {}
    local deps_path = opts.deps_path or (result and result.deps_path)
    if opts.cleanup_deps ~= false then
        compiler_dependencies.cleanup_file(deps_path)
    end
    if
        opts.publish_diagnostics ~= false
        and diagnostics.should_publish(project)
    then
        diagnostics.publish(project, diagnostic_text(result or {}))
    elseif opts.publish_diagnostics ~= false then
        clear_compiler_diagnostics(project)
    end
    if opts.log ~= false then
        log.add("error", "compile failed", {
            code = result and result.code,
            stderr = result and result.stderr,
            stdout = result and result.stdout,
        })
    end
    if opts.emit ~= false then
        compiler_events.failed(project, result)
    end
end

function M.watch_cycle_started(project, result, opts)
    opts = opts or {}
    if opts.publish_diagnostics ~= false then
        clear_compiler_diagnostics(project)
    end
    if opts.log ~= false then
        log.add("info", "watch compile cycle started", {
            main = project.main,
            cycle = result and result.cycle,
        })
    end
    if opts.emit ~= false then
        compiler_events.cycle_started(project, result)
    end
end

function M.watch_cycle_succeeded(project, watcher, result, opts)
    opts = opts or {}
    record_compile_output(project, {
        output = opts.output,
        generation = watcher and watcher.generation,
        producer = "compile",
    })
    clear_compiler_diagnostics(project)
    compiler_dependencies.refresh_watcher(project, watcher)
    log.add("info", "watch compile cycle succeeded", {
        main = project.main,
        output = opts.output,
        cycle = result and result.cycle,
        reason = opts.reason,
    })
    compiler_events.cycle_succeeded(project, result)
end

function M.watch_cycle_failed(project, result, opts)
    opts = opts or {}
    if opts.publish_diagnostics ~= false then
        if diagnostics.should_publish(project) then
            diagnostics.publish(project, diagnostic_text(result or {}))
        else
            clear_compiler_diagnostics(project)
        end
    end
    if opts.log ~= false then
        log.add("error", "watch compile cycle failed", {
            main = project.main,
            cycle = result and result.cycle,
            reason = opts.reason,
            stderr = result and result.stderr,
            stdout = result and result.stdout,
        })
    end
    if opts.emit ~= false then
        compiler_events.cycle_failed(project, result)
    end
end

function M.watch_exited_success(project, result, deps_path)
    record_compile_output(project, { producer = "compile" })
    clear_compiler_diagnostics(project)
    compiler_dependencies.update_project(
        project,
        compiler_dependencies.take(deps_path, project.root)
    )
    log.add("info", "watch exited", { code = result and result.code })
    compiler_events.succeeded(project, result)
end

function M.watch_failed(project, result, deps_path, opts)
    opts = opts or {}
    if opts.cleanup_deps ~= false then
        compiler_dependencies.cleanup_file(deps_path)
    end
    if
        opts.publish_diagnostics ~= false
        and diagnostics.should_publish(project)
    then
        diagnostics.publish(project, diagnostic_text(result or {}))
    elseif opts.publish_diagnostics ~= false then
        clear_compiler_diagnostics(project)
    end
    if opts.log ~= false then
        log.add("error", "watch failed", {
            code = result and result.code,
            stderr = result and result.stderr,
            stdout = result and result.stdout,
        })
    end
    if opts.emit ~= false then
        compiler_events.failed(project, result)
    end
end

return M
