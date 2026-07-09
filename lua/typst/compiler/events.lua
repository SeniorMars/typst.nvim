local core_result = require("typst.core.result")
local events = require("typst.core.events")

local M = {}

-- Compiler event normalization boundary.
--
-- Parser/provider code emits small, typed compiler events here. This module
-- maps them onto the existing public User events and filters payload fields so
-- call sites do not accidentally expand the event contract.

local specs = {
    compile_start = {
        pattern = "TypstEventCompileStarted",
        event_kind = "compile_start",
        compiler_event = "started",
        status = "compiling",
    },
    compile_success = {
        pattern = "TypstEventCompileSuccess",
        event_kind = "compile_success",
        compiler_event = "success",
        status = "success",
    },
    compile_failure = {
        pattern = "TypstEventCompileFailed",
        event_kind = "compile_failure",
        compiler_event = "failed",
        status = "error",
    },
    compile_stopped = {
        pattern = "TypstEventCompileStopped",
        event_kind = "compile_stopped",
        compiler_event = "stopped",
        status = "idle",
    },
    cycle_start = {
        pattern = "TypstEventCompileStarted",
        event_kind = "cycle_start",
        compiler_event = "started",
        status = "compiling",
        watch = true,
        watch_status = "watching",
    },
    cycle_success = {
        pattern = "TypstEventCompileSuccess",
        event_kind = "cycle_success",
        compiler_event = "success",
        status = "success",
        watch = true,
        watch_status = "watching",
        last_cycle_status = "success",
    },
    cycle_failure = {
        pattern = "TypstEventCompileFailed",
        event_kind = "cycle_failure",
        compiler_event = "failed",
        status = "error",
        watch = true,
        watch_status = "watching",
        last_cycle_status = "error",
    },
}

local payload_keys = {
    "event_kind",
    "compiler_event",
    "status",
    "watch",
    "cycle",
    "generation",
    "watch_generation",
    "cycle_generation",
    "watch_status",
    "last_cycle_status",
    "output_wait_ms",
    "output_wait_attempts",
    "code",
    "reason",
    "message",
    "deps_path",
    "stale",
    "stopped",
    "idle",
    "forced",
    "provider",
}

local function copy_payload(spec, opts)
    local out = {}
    opts = opts or {}
    for _, key in ipairs(payload_keys) do
        local value
        if
            key == "status"
            and spec.event_kind ~= "compile_start"
            and spec.event_kind ~= "cycle_start"
        then
            value = opts._typst_status_authoritative == true
                    and opts.status == "stopping_failed"
                    and opts.status
                or spec.status
        else
            value = opts[key]
            if value == nil then
                value = spec[key]
            end
        end
        if value ~= nil then
            out[key] = value
        end
    end
    return out
end

--- Build the public User-event payload overrides for a compiler event.
---@param kind string Normalized compiler event kind.
---@param opts? TypstCompilerResult|table Event/result fields.
---@return string pattern Compatibility event pattern to emit.
---@return table payload Public payload overrides.
function M.payload(kind, opts)
    local spec = specs[kind]
    if not spec then
        error(
            ("typst.nvim: unknown compiler event kind %s"):format(
                tostring(kind)
            )
        )
    end
    return spec.pattern, copy_payload(spec, opts)
end

--- Emit a normalized compiler event.
---@param project TypstProject Project state used for event payload base fields.
---@param kind string Normalized compiler event kind.
---@param opts? TypstCompilerResult|table Event/result fields.
function M.emit(project, kind, opts)
    local pattern, payload = M.payload(kind, opts)
    events.emit(pattern, project, payload)
end

function M.started(project, opts)
    M.emit(project, "compile_start", opts)
end

function M.succeeded(project, opts)
    M.emit(project, "compile_success", opts)
end

function M.failed(project, opts)
    M.emit(project, "compile_failure", opts)
end

function M.stopped(project, opts)
    M.emit(project, "compile_stopped", opts)
end

function M.cycle_started(project, opts)
    M.emit(project, "cycle_start", opts)
end

function M.cycle_succeeded(project, opts)
    M.emit(project, "cycle_success", opts)
end

function M.cycle_failed(project, opts)
    M.emit(project, "cycle_failure", opts)
end

--- Emit a terminal or watch-cycle event from a normalized compiler result.
---@param project TypstProject Project state used for event payload base fields.
---@param result TypstCompilerResult Compiler result.
function M.from_result(project, result)
    if core_result.is_confirmed_stopped(result) then
        M.stopped(project, result)
    elseif result.watch == true and result.code == 0 then
        M.cycle_succeeded(project, result)
    elseif result.watch == true then
        M.cycle_failed(project, result)
    elseif result.code == 0 then
        M.succeeded(project, result)
    else
        M.failed(project, result)
    end
end

return M
