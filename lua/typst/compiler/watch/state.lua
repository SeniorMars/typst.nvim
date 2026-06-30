local compiler_dependencies = require("typst.compiler.dependencies")
local compiler_events = require("typst.compiler.events")
local compiler_output = require("typst.compiler.output")
local watch_parser = require("typst.compiler.watch.parser")
local diagnostics = require("typst.diagnostics")
local async = require("typst.core.async")
local log = require("typst.core.log")
local compiler_service = require("typst.project.services.compiler")

local M = {}

local uv = vim.uv or vim.loop
local WATCH_ERROR_DEBOUNCE_MS = 50
local WATCH_OUTPUT_WAIT_INITIAL_MS = 50
local WATCH_OUTPUT_WAIT_MAX_STEP_MS = 800
local WATCH_OUTPUT_WAIT_DEFAULT_MS = 1500
local WATCH_STREAM_LOG_INTERVAL_MS = 1000

-- State machine for `typst watch` output.
--
-- Typst emits long-lived process output instead of one result per invocation.
-- This module turns textual or structured status lines into discrete compile
-- cycles while keeping generation fields so late stream chunks cannot update a
-- replacement watcher.

local close_timer = async.close_timer

--- Close the delayed failure timer attached to a watch compile cycle.
---@param cycle? table Watch cycle state that may own a finish timer.
function M.close_cycle_finish_timer(cycle)
    if not cycle or not cycle.finish_timer then
        return
    end

    close_timer(cycle.finish_timer)
    cycle.finish_timer = nil
end

local function cycle_payload(project, watcher, code)
    local cycle = watcher.current_cycle or {}
    return {
        code = code,
        stdout = cycle.stdout or "",
        stderr = cycle.stderr or "",
        deps_path = watcher.deps_path,
        stale = false,
        stopped = false,
        watch = true,
        cycle = cycle.id,
        generation = watcher.generation,
        watch_generation = watcher.generation,
        cycle_generation = cycle.generation,
        output_wait_ms = cycle.output_wait_elapsed_ms,
        output_wait_attempts = cycle.output_wait_attempts,
    }
end

local function publish_cycle_diagnostics(project, watcher)
    if not diagnostics.should_publish(project) then
        diagnostics.clear(project)
        return
    end

    local cycle = watcher.current_cycle
    diagnostics.publish(
        project,
        cycle and ((cycle.stderr or "") .. "\n" .. (cycle.stdout or "")) or ""
    )
end

local function output_readable(output)
    return type(output) == "string"
        and output ~= ""
        and vim.fn.filereadable(output) == 1
end

local function output_wait_timeout_ms(watcher)
    local timeout = tonumber(watcher and watcher.watch_output_wait_ms)
    if timeout == nil then
        return WATCH_OUTPUT_WAIT_DEFAULT_MS
    end
    return math.max(timeout, 0)
end

local function output_wait_elapsed_ms(cycle)
    if not cycle.output_wait_started_at then
        return 0
    end
    return math.floor((uv.hrtime() - cycle.output_wait_started_at) / 1000000)
end

local function log_stream_chunk(watcher, stream, data)
    watcher.stream_log_stats = watcher.stream_log_stats or {}
    local stats = watcher.stream_log_stats[stream]
        or {
            chunks = 0,
            bytes = 0,
            last_logged_at = 0,
        }
    watcher.stream_log_stats[stream] = stats

    stats.chunks = stats.chunks + 1
    stats.bytes = stats.bytes + #data

    local now = uv.hrtime()
    local elapsed_ms = stats.last_logged_at == 0 and math.huge
        or math.floor((now - stats.last_logged_at) / 1000000)
    if elapsed_ms < WATCH_STREAM_LOG_INTERVAL_MS then
        return
    end

    log.add("debug", "watch stream received", {
        stream = stream,
        chunks = stats.chunks,
        bytes = stats.bytes,
        retained_stdout = #(watcher.stdout or ""),
        retained_stderr = #(watcher.stderr or ""),
    })
    stats.chunks = 0
    stats.bytes = 0
    stats.last_logged_at = now
end

local function schedule_missing_output_retry(
    project,
    watcher,
    cycle,
    code,
    reason
)
    local timeout_ms = output_wait_timeout_ms(watcher)
    if timeout_ms <= 0 then
        cycle.output_wait_elapsed_ms = 0
        return false
    end

    if cycle.finish_timer then
        return true
    end

    cycle.output_wait_started_at = cycle.output_wait_started_at or uv.hrtime()
    local elapsed = output_wait_elapsed_ms(cycle)
    if elapsed >= timeout_ms then
        cycle.output_wait_elapsed_ms = elapsed
        return false
    end

    cycle.output_wait_attempts = (cycle.output_wait_attempts or 0) + 1
    local next_delay = cycle.output_wait_next_ms or WATCH_OUTPUT_WAIT_INITIAL_MS
    local remaining = math.max(timeout_ms - elapsed, 1)
    local delay = math.min(next_delay, remaining)
    cycle.output_wait_next_ms =
        math.min(next_delay * 2, WATCH_OUTPUT_WAIT_MAX_STEP_MS)

    local timer = uv.new_timer()
    if not timer then
        return false
    end

    cycle.finish_timer = timer
    timer:start(
        delay,
        0,
        vim.schedule_wrap(function()
            if cycle.finish_timer == timer then
                cycle.finish_timer = nil
            end
            close_timer(timer)

            if
                (compiler_service.get(project) or {}).watcher ~= watcher
                or watcher.current_cycle ~= cycle
                or cycle.finished
            then
                return
            end

            M.finish_cycle(project, watcher, code, reason)
        end)
    )
    return true
end

--- Complete the current `typst watch` compile cycle and notify consumers.
---@param project table Project state whose compiler service receives the result.
---@param watcher table Active watcher state that owns the current cycle.
---@param code integer Exit-like status code for the cycle.
---@param reason? string Parser/status reason associated with the cycle finish.
function M.finish_cycle(project, watcher, code, reason)
    local cycle = watcher.current_cycle
    if not cycle or cycle.finished then
        return
    end

    local output = (compiler_service.get(project) or {}).output
    if
        code == 0
        and not output_readable(output)
        and schedule_missing_output_retry(project, watcher, cycle, code, reason)
    then
        log.add("debug", "watch success output missing; retrying briefly", {
            main = project.main,
            output = output,
            cycle = cycle.id,
            attempts = cycle.output_wait_attempts,
            elapsed_ms = output_wait_elapsed_ms(cycle),
            timeout_ms = output_wait_timeout_ms(watcher),
        })
        return
    end

    M.close_cycle_finish_timer(cycle)
    cycle.finished = true
    watcher.currently_compiling = false
    watcher.last_cycle_id = cycle.id
    watcher.last_cycle_generation = cycle.generation
    cycle.output_wait_elapsed_ms = output_wait_elapsed_ms(cycle)
    local result = cycle_payload(project, watcher, code)
    compiler_service.set(project, {
        last_result = result,
        status = "watching",
        watch_cycle = cycle.id,
        last_cycle_generation = cycle.generation,
    })

    if code == 0 and not output_readable(output) then
        -- Typst can report a successful watch cycle even when the expected
        -- output path was not written, for example after bad output options or
        -- tool wrappers. Treat that as a compile failure so diagnostics and
        -- preview do not refresh stale PDFs.
        local message = ("Typst watch reported success but did not create %s"):format(
            output
        )
        cycle.stderr = compiler_output.append_bounded(
            cycle.stderr,
            ("%s:1:1: error: %s\n"):format(project.main, message)
        )
        result.code = 1
        result.stderr = cycle.stderr
        result.output_wait_ms = cycle.output_wait_elapsed_ms
        result.output_wait_attempts = cycle.output_wait_attempts
        code = 1
        reason = "missing output"
    end

    if code == 0 then
        require("typst.workflows.artifacts").record_owned(project, {
            path = output,
            producer = "compile",
            generation = watcher.generation,
        })
        watcher.last_cycle_status = "success"
        compiler_service.set(project, {
            watch_cycle_status = watcher.last_cycle_status,
        })
        diagnostics.clear(project)
        compiler_dependencies.refresh_watcher(project, watcher)
        log.add("info", "watch compile cycle succeeded", {
            main = project.main,
            output = output,
            cycle = cycle.id,
            reason = reason,
        })
        result.last_cycle_status = watcher.last_cycle_status
        compiler_events.cycle_succeeded(project, result)
    else
        watcher.last_cycle_status = "error"
        compiler_service.set(project, {
            watch_cycle_status = watcher.last_cycle_status,
        })
        publish_cycle_diagnostics(project, watcher)
        log.add("error", "watch compile cycle failed", {
            main = project.main,
            cycle = cycle.id,
            reason = reason,
            stderr = result.stderr,
            stdout = result.stdout,
        })
        result.last_cycle_status = watcher.last_cycle_status
        result.reason = reason
        compiler_events.cycle_failed(project, result)
    end

    if watcher.callback then
        watcher.callback(result)
    end
end

local function schedule_error_cycle_finish(project, watcher, cycle, reason)
    cycle.pending_error_reason = reason
    M.close_cycle_finish_timer(cycle)

    -- Error output can arrive as several lines after the status marker. Delay
    -- the terminal failure briefly so diagnostics receive the whole burst.
    local timer = uv.new_timer()
    cycle.finish_timer = timer
    timer:start(
        WATCH_ERROR_DEBOUNCE_MS,
        0,
        vim.schedule_wrap(function()
            if cycle.finish_timer == timer then
                cycle.finish_timer = nil
            end
            close_timer(timer)

            if
                (compiler_service.get(project) or {}).watcher ~= watcher
                or watcher.current_cycle ~= cycle
                or cycle.finished
            then
                return
            end

            M.finish_cycle(
                project,
                watcher,
                1,
                cycle.pending_error_reason or "compiled with errors"
            )
        end)
    )
end

--- Start a new watch compile cycle after retiring any unfinished cycle.
---@param project table Project state whose compiler service owns this watcher.
---@param watcher table Watcher state receiving the new cycle metadata.
local function start_cycle(project, watcher)
    if watcher.current_cycle and not watcher.current_cycle.finished then
        local reason = watcher.current_cycle.pending_error_reason
            or "interrupted by next cycle"
        M.finish_cycle(project, watcher, 1, reason)
    end

    watcher.cycle = (watcher.cycle or 0) + 1
    local compiler_state = compiler_service.get(project) or {}
    local watch_cycle_generation = (compiler_state.watch_cycle_generation or 0)
        + 1
    compiler_service.set(project, {
        watch_cycle_generation = watch_cycle_generation,
    })
    watcher.currently_compiling = true
    watcher.last_cycle_status = "compiling"
    watcher.cycle_generation = watch_cycle_generation
    watcher.current_cycle = {
        id = watcher.cycle,
        generation = watcher.cycle_generation,
        stdout = "",
        stderr = "",
        started_at = uv.hrtime(),
        finished = false,
    }

    diagnostics.clear(project)
    log.add("info", "watch compile cycle started", {
        main = project.main,
        cycle = watcher.cycle,
    })
    compiler_events.cycle_started(project, {
        watch = true,
        cycle = watcher.cycle,
        generation = watcher.generation,
        watch_generation = watcher.generation,
        cycle_generation = watcher.cycle_generation,
        watch_status = "watching",
        last_cycle_status = watcher.last_cycle_status,
    })
end

--- Parse one line of watch output and update the active compile cycle.
---@param project table Project state whose watcher produced the line.
---@param watcher table Active watcher state.
---@param stream '"stdout"'|'"stderr"' Output stream that produced the line.
---@param line string Complete output line without the trailing newline.
function M.handle_line(project, watcher, stream, line)
    local parsed = watch_parser.parse(line, {
        version = watcher.typst_version,
        structured_only = watcher.watch_output == "structured",
    })
    if parsed and parsed.profile == "structured-json" then
        watcher.structured_output_seen = true
    end
    if parsed and parsed.event == "start" then
        start_cycle(project, watcher)
        return
    end

    if not watcher.current_cycle then
        if parsed and parsed.event == "unknown" then
            watcher.unrecognized_status_lines = (
                watcher.unrecognized_status_lines or 0
            ) + 1
            if watcher.last_unrecognized_status_line ~= parsed.line then
                watcher.last_unrecognized_status_line = parsed.line
                log.add("warn", "unrecognized Typst watch status output", {
                    line = parsed.line,
                    reason = parsed.reason,
                    count = watcher.unrecognized_status_lines,
                })
            end
        end
        return
    end

    local cycle = watcher.current_cycle
    cycle[stream] = compiler_output.append_bounded(cycle[stream], line .. "\n")

    if parsed and parsed.event == "success" then
        M.finish_cycle(project, watcher, 0, line)
    elseif parsed and parsed.event == "error" then
        schedule_error_cycle_finish(project, watcher, cycle, line)
    elseif parsed and parsed.event == "unknown" then
        watcher.unrecognized_status_lines = (
            watcher.unrecognized_status_lines or 0
        ) + 1
        if watcher.last_unrecognized_status_line ~= parsed.line then
            watcher.last_unrecognized_status_line = parsed.line
            log.add("warn", "unrecognized Typst watch status output", {
                line = parsed.line,
                reason = parsed.reason,
                count = watcher.unrecognized_status_lines,
                cycle = cycle.id,
            })
        end
    elseif watcher.last_cycle_status == "error" then
        compiler_service.set(project, {
            last_result = cycle_payload(project, watcher, 1),
        })
        publish_cycle_diagnostics(project, watcher)
    end
end

--- Append raw watch output and dispatch each complete line to the parser.
---@param project table Project state whose watcher produced the data.
---@param watcher table Active watcher state.
---@param stream '"stdout"'|'"stderr"' Output stream that produced the data.
---@param data? string Raw process output chunk.
function M.append_stream(project, watcher, stream, data)
    if not data or data == "" then
        return
    end

    if
        not watcher
        or (compiler_service.get(project) or {}).watcher ~= watcher
        or (compiler_service.get(project) or {}).watch_generation
            ~= watcher.generation
    then
        -- libuv may deliver buffered data after a watcher has been replaced.
        -- Drop it instead of letting an old process finish the current cycle.
        return
    end

    watcher[stream] = compiler_output.append_bounded(watcher[stream], data)
    log_stream_chunk(watcher, stream, data)

    for _, line in ipairs(compiler_output.complete_lines(watcher, stream, data)) do
        M.handle_line(project, watcher, stream, line)
    end
end

--- Drain queued raw stream chunks in arrival order.
---@param project table Project state whose watcher produced the chunks.
---@param watcher table Active watcher state.
function M.drain_stream_queue(project, watcher)
    if not watcher then
        return
    end

    watcher.stream_queue_scheduled = false
    local queue = watcher.stream_queue or {}
    watcher.stream_queue = {}

    for _, item in ipairs(queue) do
        M.append_stream(project, watcher, item.stream, item.data)
    end
end

--- Queue raw watch output from a libuv stream callback.
---@param project table Project state whose watcher produced the data.
---@param watcher table Active watcher state.
---@param stream '"stdout"'|'"stderr"' Output stream that produced the data.
---@param data? string Raw process output chunk.
function M.enqueue_stream(project, watcher, stream, data)
    if not watcher or not data or data == "" then
        return
    end

    watcher.stream_queue = watcher.stream_queue or {}
    watcher.stream_queue[#watcher.stream_queue + 1] = {
        stream = stream,
        data = data,
    }

    if watcher.stream_queue_scheduled then
        return
    end

    watcher.stream_queue_scheduled = true
    vim.schedule(function()
        M.drain_stream_queue(project, watcher)
    end)
end

return M
