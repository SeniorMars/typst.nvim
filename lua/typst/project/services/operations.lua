local log = require("typst.core.log")
local cancel = require("typst.core.cancel")
local pending = require("typst.core.pending")
local core_result = require("typst.core.result")
local services = require("typst.project.services")

local M = {}

-- Per-project operation registry for user-triggered async work. Compiler/watch
-- state owns the actual Typst processes; this layer gives commands a common
-- place to report, cancel, and summarize concurrent work.

---@class TypstOperationRecord
---@field id integer Monotonic operation id within the project service.
---@field kind string Operation kind used for active/last summaries.
---@field generation integer Per-kind generation used to ignore older summaries.
---@field started_at integer `uv.hrtime()` timestamp when the operation began.
---@field finished boolean True once the operation has been settled.
---@field finished_at integer? `uv.hrtime()` timestamp when the operation settled.
---@field retained boolean? True when the operation moved to retained orphan tracking.
---@field retained_at integer? `uv.hrtime()` timestamp when the operation became retained.
---@field result any Summary-safe copy of the terminal result.
---@field handle any Native pending handle returned by the underlying workflow.
---@field [string] any

---@class TypstOperationCancelSummary
---@field total integer Number of active records considered for cancellation.
---@field cancelled integer Number of records cancelled and cleared.
---@field failed integer Number of records that could not be cancelled cleanly.
---@field stale integer Number of stale records cleared without a live handle.
---@field uncancellable integer Number of live unsupported handles retained.
---@field retained integer Number of records moved to retained-orphan tracking.
---@field outcomes table[] Per-record cancellation outcome rows.

local scalar_types = {
    boolean = true,
    number = true,
    string = true,
}

local function copy_summary_value(value, depth, seen)
    local value_type = type(value)
    if value == nil or scalar_types[value_type] then
        return value
    end
    if value_type ~= "table" or depth <= 0 then
        return nil
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local out = {}
    seen[value] = out
    for key, child in pairs(value) do
        if scalar_types[type(key)] then
            local copied = copy_summary_value(child, depth - 1, seen)
            if copied ~= nil then
                out[key] = copied
            end
        end
    end
    return out
end

local function operation_service(project)
    local service = services.operations(project)
    if not service then
        return nil
    end
    service.active_by_id = service.active_by_id or {}
    service.active_by_kind = service.active_by_kind or {}
    service.retained_by_id = service.retained_by_id or {}
    service.retained_by_kind = service.retained_by_kind or {}
    service.generations = service.generations or {}
    service.last = service.last or {}
    service.next_id = service.next_id or 0
    return service
end

local function result_summary(result)
    if type(result) ~= "table" then
        return result
    end

    local summary = {}
    for _, key in ipairs({
        "ok",
        "code",
        "signal",
        "reason",
        "message",
        "stopped",
        "forced",
        "idle",
        "stale",
        "orphaned",
        "spawn_failed",
        "artifacts",
        "outputs",
        "path",
        "output",
    }) do
        local value = result[key]
        if value ~= nil then
            if type(value) == "table" then
                summary[key] = copy_summary_value(value, 4)
            else
                summary[key] = value
            end
        end
    end
    return summary
end

--- Open a tracked project operation record.
---@param project table Project state whose operation service owns the record.
---@param kind string Operation kind used in active and last-result snapshots.
---@return TypstOperationRecord? record Active record, or nil when no service exists.
function M.begin(project, kind)
    local service = operation_service(project)
    if not service then
        return nil
    end

    local generations = service.generations
    generations[kind] = (generations[kind] or 0) + 1
    service.next_id = (service.next_id or 0) + 1

    local record = {
        id = service.next_id,
        kind = kind,
        generation = generations[kind],
        started_at = vim.loop.hrtime(),
        finished = false,
    }
    service.active_by_id[record.id] = record
    service.active_by_kind[kind] = service.active_by_kind[kind] or {}
    service.active_by_kind[kind][record.id] = true
    return record
end

local function remove_active_record(service, record)
    if not service or not record or not record.id then
        return
    end

    if service.active_by_id[record.id] == record then
        service.active_by_id[record.id] = nil
    end

    local by_kind = service.active_by_kind[record.kind]
    if by_kind then
        by_kind[record.id] = nil
        if next(by_kind) == nil then
            service.active_by_kind[record.kind] = nil
        end
    end
end

local function remove_retained_record(service, record)
    if not service or not record or not record.id then
        return
    end

    if service.retained_by_id[record.id] == record then
        service.retained_by_id[record.id] = nil
    end

    local by_kind = service.retained_by_kind[record.kind]
    if by_kind then
        by_kind[record.id] = nil
        if next(by_kind) == nil then
            service.retained_by_kind[record.kind] = nil
        end
    end
end

local function add_retained_record(service, record)
    if not service or not record or not record.id then
        return
    end

    service.retained_by_id[record.id] = record
    service.retained_by_kind[record.kind] = service.retained_by_kind[record.kind]
        or {}
    service.retained_by_kind[record.kind][record.id] = true
end

--- Settle an operation record and store its summary on project services.
---@param project table Project state whose operation service owns the record.
---@param record TypstOperationRecord|TypstProjectOperationRecord? Operation record returned by `begin`.
---@param result any Native terminal result returned by the underlying workflow.
---@return any result The original result, unchanged.
function M.finish(project, record, result)
    if not record or record.finished then
        return result
    end

    local kind = record.kind
    local service = operation_service(project)
    record.finished = true
    record.finished_at = vim.loop.hrtime()
    record.result = result_summary(result)

    if service then
        remove_active_record(service, record)
        remove_retained_record(service, record)
        local previous = service.last[record.kind]
        if not previous or record.generation >= (previous.generation or 0) then
            service.last[record.kind] = {
                id = record.id,
                generation = record.generation,
                started_at = record.started_at,
                finished_at = record.finished_at,
                result = record.result,
            }
        end
    end

    if
        type(project) == "table"
        and next(project.bufs or {}) == nil
        and not services.has_active_resources(project)
    then
        local ok, project_registry = pcall(require, "typst.project")
        if ok and type(project_registry.prune) == "function" then
            project_registry.prune(
                project,
                ("operation %s finished after detach"):format(kind or "unknown")
            )
        end
    end

    return result
end

--- Move an active operation record into retained-orphan tracking.
---@param project table Project state whose operation service owns the record.
---@param record TypstOperationRecord|TypstProjectOperationRecord? Operation record returned by `begin`.
---@param result any Best-known retained orphan result.
---@return any result The original result, unchanged.
function M.retain(project, record, result)
    if not record or record.finished then
        return result
    end

    local service = operation_service(project)
    record.retained = true
    record.retained_at = vim.loop.hrtime()
    record.result = result_summary(result)

    if service then
        remove_active_record(service, record)
        add_retained_record(service, record)
    end

    return result
end

--- Clear one active operation record or all active records for a kind.
---@param project table Project state whose active operation index is mutated.
---@param target string|TypstOperationRecord|TypstProjectOperationRecord Operation kind or specific record.
function M.clear(project, target)
    local service = operation_service(project)
    if not service then
        return
    end
    if type(target) == "table" then
        remove_active_record(service, target)
        remove_retained_record(service, target)
        return
    end

    local by_kind = vim.deepcopy(service.active_by_kind[target] or {})
    for id in pairs(by_kind) do
        service.active_by_id[id] = nil
    end
    service.active_by_kind[target] = nil

    local retained_by_kind =
        vim.deepcopy(service.retained_by_kind[target] or {})
    for id in pairs(retained_by_kind) do
        service.retained_by_id[id] = nil
    end
    service.retained_by_kind[target] = nil
end

local function cancellable_handle(record)
    local handle = record and record.handle
    if
        type(handle) == "table"
        and type(handle.operation) == "table"
        and type(handle.operation.cancel) == "function"
    then
        return handle.operation
    end
    if type(handle) == "table" and type(handle.cancel) == "function" then
        return handle
    end
    return nil
end

local function has_live_uncancellable_handle(record)
    local handle = record and record.handle
    if handle == nil or handle == false then
        return false
    end
    if type(handle) == "table" and handle.finished == true then
        return false
    end
    if type(handle) == "table" and handle.pending == false then
        return false
    end
    return true
end

local function add_cancel_outcome(summary, record, outcome, result)
    summary.outcomes = summary.outcomes or {}
    summary.outcomes[#summary.outcomes + 1] = {
        id = record and record.id,
        kind = record and record.kind,
        outcome = outcome,
        reason = type(result) == "table" and result.reason or nil,
        retained = outcome == "retained" or outcome == "uncancellable",
    }
end

--- Cancel cancellable non-compiler operations for a project.
---@param project table Project state whose active operations should be cancelled.
---@param opts? table Cancellation options; `skip` maps operation kinds to true.
---@return TypstOperationCancelSummary summary Cancellation totals.
function M.cancel_project(project, opts)
    opts = opts or {}
    local service = operation_service(project)
    if not service then
        return {
            total = 0,
            cancelled = 0,
            failed = 0,
            stale = 0,
            uncancellable = 0,
            retained = 0,
            outcomes = {},
        }
    end

    local skip = opts.skip
        or {
            compile = true,
            watch = true,
            stop = true,
        }
    local summary = {
        total = 0,
        cancelled = 0,
        failed = 0,
        stale = 0,
        uncancellable = 0,
        retained = 0,
        outcomes = {},
    }

    local records = vim.tbl_values(service.active_by_id or {})
    table.sort(records, function(left, right)
        return (left.id or 0) < (right.id or 0)
    end)
    for _, active_record in ipairs(records) do
        local kind = active_record.kind
        if not skip[kind] then
            summary.total = summary.total + 1
            local handle = cancellable_handle(active_record)
            if handle then
                local ok, cancel_result = cancel.call(handle, opts)
                local raw_handle = active_record and active_record.handle
                local operation = raw_handle and raw_handle.operation
                if
                    type(operation) ~= "table"
                    and type(raw_handle) == "table"
                    and type(raw_handle.wait) == "function"
                then
                    operation = raw_handle
                end
                if
                    opts.wait ~= false
                    and type(operation) == "table"
                    and type(operation.wait) == "function"
                then
                    pcall(
                        operation.wait,
                        operation,
                        opts.wait_timeout_ms or 1000
                    )
                end
                if
                    type(operation) == "table"
                    and operation.state == "finished"
                then
                    ok = operation.stopped ~= false
                end
                local retained = type(operation) == "table"
                    and operation.state == "orphaned-retained"
                if
                    type(operation) == "table"
                    and (
                        operation.orphaned == true
                        or operation.state == "running"
                        or operation.state == "stopping"
                        or operation.state == "orphaned-running"
                    )
                then
                    ok = false
                end
                if retained then
                    summary.retained = summary.retained + 1
                    M.retain(
                        project,
                        active_record,
                        operation.result or cancel_result or operation
                    )
                    add_cancel_outcome(
                        summary,
                        active_record,
                        "retained",
                        operation.result or cancel_result or operation
                    )
                elseif ok then
                    summary.cancelled = summary.cancelled + 1
                    M.clear(project, active_record)
                    add_cancel_outcome(
                        summary,
                        active_record,
                        "cancelled",
                        cancel_result
                    )
                else
                    summary.failed = summary.failed + 1
                    add_cancel_outcome(
                        summary,
                        active_record,
                        "failed",
                        cancel_result
                    )
                end
            else
                if has_live_uncancellable_handle(active_record) then
                    summary.uncancellable = summary.uncancellable + 1
                    summary.retained = summary.retained + 1
                    M.retain(project, active_record, {
                        ok = false,
                        reason = "uncancellable_handle",
                        message = "operation handle does not implement cancel",
                        kind = kind,
                    })
                    add_cancel_outcome(
                        summary,
                        active_record,
                        "uncancellable",
                        {
                            reason = "uncancellable_handle",
                        }
                    )
                else
                    summary.stale = summary.stale + 1
                    M.clear(project, active_record)
                    add_cancel_outcome(summary, active_record, "stale")
                end
            end
        end
    end

    return summary
end

local function protected_callback(callback, ...)
    if not callback then
        return
    end

    local ok, err = pcall(callback, ...)
    if not ok then
        log.add("error", "project operation callback failed", {
            error = err,
        })
    end
end

local function missing_project_result(kind, callback)
    local result = {
        ok = false,
        pending = false,
        reason = "missing_project",
        message = ("Typst %s requires a project"):format(kind or "operation"),
    }
    protected_callback(callback, result)
    return result
end

local function terminal_result(result)
    if result == nil then
        return false
    end
    if type(result) ~= "table" then
        return true
    end
    if result.pending then
        return false
    end
    return result.ok ~= nil
        or result.code ~= nil
        or result.reason ~= nil
        or result.stopped ~= nil
        or result.idle ~= nil
        or result.artifacts ~= nil
        or result.outputs ~= nil
        or result.path ~= nil
        or result.output ~= nil
end

local function copy_terminal_fields(proxy, result)
    if type(result) ~= "table" then
        return
    end
    for _, key in ipairs({
        "ok",
        "code",
        "signal",
        "reason",
        "message",
        "stopped",
        "state",
        "stale",
        "orphaned",
    }) do
        if result[key] ~= nil then
            proxy[key] = result[key]
        end
    end
end

local function settle_deferred_proxy(proxy, result)
    if proxy.finished == true then
        return result
    end
    proxy.pending = false
    proxy.finished = true
    proxy.result = result
    copy_terminal_fields(proxy, result)
    return result
end

local function on_finish_style(source)
    if type(source) ~= "table" then
        return "colon"
    end
    if
        source.on_finish_style == "dot"
        or source._typst_on_finish_style == "dot"
    then
        return "dot"
    end
    return "colon"
end

local function subscribe_deferred_proxy(proxy, actual)
    if type(actual) ~= "table" or actual.pending ~= true then
        settle_deferred_proxy(proxy, actual)
        return
    end

    local ok, err = pending.subscribe(actual, function(result)
        settle_deferred_proxy(proxy, result)
    end, { style = on_finish_style(actual) })
    if ok then
        return
    end

    local operation = actual.operation
    if type(operation) == "table" then
        local op_ok, op_err = pending.subscribe(operation, function(finished)
            settle_deferred_proxy(proxy, finished.result or actual)
        end, { style = on_finish_style(operation) })
        if op_ok then
            return
        end
        err = op_err or err
    end

    settle_deferred_proxy(proxy, {
        ok = false,
        pending = false,
        reason = "pending_unobservable",
        message = "Deferred operation returned a pending handle without an observable finish callback",
        error = err and tostring(err) or nil,
    })
end

-- Wrap user-facing operations in a project-scoped record without hiding their
-- native return value. Synchronous results finish the record immediately; pending
-- handles stay active until their callback settles the same operation exactly
-- once.
local function run(project, kind, callback, runner, opts)
    opts = opts or {}
    if type(project) ~= "table" then
        return runner(callback)
    end

    if not opts.allow_reentrant then
        local events = require("typst.core.events")
        if events.in_user_event() then
            -- Avoid mutating project services while a typst.nvim user event is
            -- being delivered. Defer the operation and return a cancellable
            -- proxy so callers still get a handle immediately.
            local cancelled = false
            local actual = nil
            local proxy = {
                ok = false,
                pending = true,
                deferred = true,
                cancel_style = "dot",
                kind = kind,
            }
            proxy.cancel = function(cancel_opts, cancel_callback)
                if actual then
                    local handle = actual.operation or actual
                    if
                        type(handle) == "table"
                        and type(handle.cancel) == "function"
                    then
                        local stopped, result =
                            cancel.call(handle, cancel_opts, cancel_callback)
                        if not (type(result) == "table" and result.pending) then
                            settle_deferred_proxy(proxy, result)
                        end
                        return stopped, result
                    end
                end
                cancelled = true
                local result = {
                    ok = false,
                    stopped = true,
                    reason = (cancel_opts and cancel_opts.reason)
                        or "cancelled",
                }
                if type(cancel_callback) == "function" then
                    protected_callback(cancel_callback, true, result)
                end
                settle_deferred_proxy(proxy, result)
                return true, result
            end

            events.defer_state_change("operation:" .. kind, function()
                if cancelled then
                    settle_deferred_proxy(proxy, proxy.result or {
                        ok = false,
                        stopped = true,
                        reason = "cancelled",
                    })
                    return
                end
                actual = run(
                    project,
                    kind,
                    callback,
                    runner,
                    vim.tbl_extend("force", opts, { allow_reentrant = true })
                )
                proxy.handle = actual
                proxy.operation = type(actual) == "table" and actual.operation
                    or nil
                subscribe_deferred_proxy(proxy, actual)
            end)
            return proxy
        end
    end

    local record = M.begin(project, kind)
    local callback_called = false
    local wrapped_callback = function(result, ...)
        if
            opts.streaming
            and type(result) == "table"
            and result.watch == true
            and result.stopped ~= true
        then
            -- Watch compile cycles are intermediate events, not terminal
            -- operation results. Keep the operation active until the watcher
            -- stops or fails.
            protected_callback(callback, result, ...)
            return
        end

        if callback_called then
            log.add("warn", "ignored duplicate project operation callback", {
                kind = kind,
                id = record and record.id,
            })
            return
        end
        callback_called = true
        M.finish(project, record, result)
        protected_callback(callback, result, ...)
    end

    local ok, result = xpcall(function()
        return runner(wrapped_callback)
    end, debug.traceback)

    if not ok then
        M.finish(project, record, {
            ok = false,
            reason = "exception",
            message = result,
        })
        error(result, 0)
    end

    if record and type(result) == "table" then
        record.handle = result
    end

    if not callback_called and terminal_result(result) then
        M.finish(project, record, result)
    end

    return result
end

local function finish_stop(project, record, callback)
    local called = false
    return function(result, ...)
        if called then
            log.add("warn", "ignored duplicate compiler stop callback", {
                id = record and record.id,
            })
            return
        end
        called = true
        if core_result.is_confirmed_stopped(result) then
            M.clear(project, "compile")
            M.clear(project, "watch")
        end
        M.finish(project, record, result)
        protected_callback(callback, result, ...)
    end
end

--- Run a project compile under operation tracking.
---@param project table? Project state to track.
---@param opts? table Compile options.
---@param callback? fun(result:TypstCompilerResult) Terminal result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native compiler handle or synchronous result.
function M.compile(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("compile", callback)
    end
    return run(project, "compile", callback, function(done)
        return require("typst.compiler.api").compile(
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Compile a selected Typst fragment under operation tracking.
---@param project table? Parent project state used for tracking and context.
---@param opts? table Selection compile options.
---@param callback? fun(result:table) Terminal result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native compile-selected handle or synchronous result.
function M.compile_selected(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("compile_selected", callback)
    end
    return run(project, "compile_selected", callback, function(done)
        return require("typst.compiler.api").compile_selected(
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Start a watched compile under operation tracking.
---@param project table? Project state whose watch operation should be tracked.
---@param opts? table Watch options.
---@param callback? fun(result:TypstCompilerResult) Watch-cycle or terminal result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native watcher handle or synchronous result.
function M.watch(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("watch", callback)
    end
    return run(project, "watch", callback, function(done)
        return require("typst.compiler.api").watch(project, opts, done, notify)
    end, { streaming = true })
end

--- Stop compiler work under operation tracking.
---@param project table? Project state whose compiler work should stop.
---@param callback? fun(result:TypstCompilerResult) Stop result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native stop handle, deferred proxy, synchronous result, or nil.
function M.stop(project, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("stop", callback)
    end

    local events = require("typst.core.events")
    if events.in_user_event() then
        local cancelled = false
        local actual = nil
        local proxy = {
            ok = false,
            pending = true,
            deferred = true,
            cancel_style = "dot",
            kind = "stop",
        }
        proxy.cancel = function(cancel_opts, cancel_callback)
            if actual and type(actual.cancel) == "function" then
                local stopped, result =
                    cancel.call(actual, cancel_opts, cancel_callback)
                if not (type(result) == "table" and result.pending) then
                    settle_deferred_proxy(proxy, result)
                end
                return stopped, result
            end
            cancelled = true
            local result = {
                ok = false,
                stopped = true,
                reason = (cancel_opts and cancel_opts.reason) or "cancelled",
            }
            if type(cancel_callback) == "function" then
                protected_callback(cancel_callback, true, result)
            end
            settle_deferred_proxy(proxy, result)
            return true, result
        end

        events.defer_state_change("operation:stop", function()
            if cancelled then
                settle_deferred_proxy(proxy, proxy.result or {
                    ok = false,
                    stopped = true,
                    reason = "cancelled",
                })
                return
            end
            actual = M.stop(project, callback, notify)
            proxy.handle = actual
            proxy.operation = type(actual) == "table" and actual.operation
                or nil
            subscribe_deferred_proxy(proxy, actual)
        end)
        return proxy
    end

    local record = M.begin(project, "stop")
    local ok, result = xpcall(function()
        return require("typst.compiler.api").stop(
            project,
            finish_stop(project, record, callback),
            notify
        )
    end, debug.traceback)
    if not ok then
        M.finish(project, record, {
            ok = false,
            reason = "exception",
            message = result,
        })
        error(result, 0)
    end
    if terminal_result(result) then
        M.finish(project, record, result)
    end
    return result
end

--- Force-clear unconfirmed external compiler state for a project.
---@param project table? Project state whose compiler state should be discarded.
---@param opts? table Force-clear options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return TypstCompilerResult result Force-clear status.
function M.force_clear_compiler(project, opts, notify)
    local result =
        require("typst.compiler.api").force_clear(project, opts, notify)
    if result and result.ok and result.discarded == true then
        if project then
            M.clear(project, "compile")
            M.clear(project, "watch")
            M.clear(project, "stop")
            require("typst.project").prune(project, "compiler force clear")
        end
    end
    return result
end

--- Stop compiler work for all projects and clear settled operation records.
---@param opts? table Stop-all options forwarded to the compiler API.
---@param callback? fun(result:TypstCompilerResult, project?:table, summary?:table) Per-project stop callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table summary Aggregate compiler stop summary.
function M.stop_all(opts, callback, notify)
    return require("typst.compiler.api").stop_all(
        opts,
        function(result, project, summary)
            if project and core_result.is_confirmed_stopped(result) then
                M.clear(project, "compile")
                M.clear(project, "watch")
            end
            protected_callback(callback, result, project, summary)
        end,
        notify
    )
end

--- Format a Typst buffer under operation tracking.
---@param project table? Project state used for operation tracking.
---@param opts? table Formatting options.
---@param callback? fun(result:table) Terminal formatting result callback.
---@return unknown result Native formatting handle or synchronous result.
function M.format(project, opts, callback)
    return run(project, "format", callback, function(done)
        return require("typst.formatting").format(opts, done)
    end)
end

--- Run Typst lint under operation tracking.
---@param project table? Project state used for operation tracking.
---@param opts? table Lint options.
---@param callback? fun(result:table) Terminal lint result callback.
---@return unknown result Native lint handle or synchronous result.
function M.lint(project, opts, callback)
    return run(project, "lint", callback, function(done)
        return require("typst.lint").lint(opts, done)
    end)
end

--- Run Typst grammar checks under operation tracking.
---@param project table? Project state used for operation tracking.
---@param opts? table Grammar-check options.
---@param callback? fun(result:table) Terminal grammar result callback.
---@return unknown result Native grammar-check handle or synchronous result.
function M.grammar(project, opts, callback)
    return run(project, "grammar", callback, function(done)
        return require("typst.syntax.grammar").check(opts, done)
    end)
end

--- Render the current Typst fragment under operation tracking.
---@param project table? Project state used for render context and tracking.
---@param opts? table Fragment render options.
---@param callback? fun(result:table) Terminal render result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native render handle or synchronous result.
function M.render_fragment(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("render_fragment", callback)
    end
    return run(project, "render_fragment", callback, function(done)
        return require("typst.workflows.render").fragment(
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Render a Typst equation fragment under operation tracking.
---@param project table? Project state used for render context and tracking.
---@param opts? table Equation render options.
---@param callback? fun(result:table) Terminal render result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native render handle or synchronous result.
function M.render_equation(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("render_equation", callback)
    end
    return run(project, "render_equation", callback, function(done)
        return require("typst.workflows.render").equation(
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Render a Typst image artifact under operation tracking.
---@param project table? Project state used for render context and tracking.
---@param opts? table Image render options.
---@param callback? fun(result:table) Terminal render result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native render handle or synchronous result.
function M.render_image(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("render_image", callback)
    end
    return run(project, "render_image", callback, function(done)
        return require("typst.workflows.render").image(
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Render one Typst page under operation tracking.
---@param project table? Project state used for render context and tracking.
---@param opts? table Page render options.
---@param callback? fun(result:table) Terminal render result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native render handle or synchronous result.
function M.render_page(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("render_page", callback)
    end
    return run(project, "render_page", callback, function(done)
        return require("typst.workflows.render").page(
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Export a project artifact under operation tracking.
---@param project table? Project state used for export context and tracking.
---@param opts? table Export options.
---@param callback? fun(result:table) Terminal export result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native export handle or synchronous result.
function M.export(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("export", callback)
    end
    return run(project, "export", callback, function(done)
        return require("typst.workflows.artifacts").export(
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Evaluate Typst code under operation tracking.
---@param project table? Project state used for eval context and tracking.
---@param opts? table Eval options.
---@param callback? fun(result:table) Terminal eval result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native eval handle or synchronous result.
function M.eval(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("eval", callback)
    end
    return run(project, "eval", callback, function(done)
        return require("typst.workflows.eval").eval(project, opts, done, notify)
    end)
end

--- Evaluate the selected Typst source under operation tracking.
---@param project table? Project state used for eval context and tracking.
---@param opts? table Selection eval options; includes the target buffer.
---@param callback? fun(result:table) Terminal eval result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native eval handle or synchronous result.
function M.eval_selection(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("eval_selection", callback)
    end
    return run(project, "eval_selection", callback, function(done)
        return require("typst.workflows.eval").eval_selection(
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Inspect Typst evaluation output under operation tracking.
---@param project table? Project state used for inspect context and tracking.
---@param opts? table Inspect options.
---@param callback? fun(result:table) Terminal inspect result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native inspect handle or synchronous result.
function M.inspect(project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result("inspect", callback)
    end
    return run(project, "inspect", callback, function(done)
        return require("typst.workflows.eval").inspect(
            project,
            opts,
            done,
            notify
        )
    end)
end

local function development(kind, project, opts, callback, notify)
    if type(project) ~= "table" then
        return missing_project_result(kind, callback)
    end
    return run(project, kind, callback, function(done)
        return require("typst.workflows.development")[kind](
            project,
            opts,
            done,
            notify
        )
    end)
end

--- Run Typst profiling under operation tracking.
---@param project table? Project state used for development workflow context.
---@param opts? table Profile options.
---@param callback? fun(result:table) Terminal profile result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native profile handle or synchronous result.
function M.profile(project, opts, callback, notify)
    return development("profile", project, opts, callback, notify)
end

--- Run Typst tests under operation tracking.
---@param project table? Project state used for development workflow context.
---@param opts? table Test options.
---@param callback? fun(result:table) Terminal test result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native test handle or synchronous result.
function M.test(project, opts, callback, notify)
    return development("test", project, opts, callback, notify)
end

--- Run Typst benchmarks under operation tracking.
---@param project table? Project state used for development workflow context.
---@param opts? table Benchmark options.
---@param callback? fun(result:table) Terminal benchmark result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native benchmark handle or synchronous result.
function M.bench(project, opts, callback, notify)
    return development("bench", project, opts, callback, notify)
end

--- Run Typst coverage workflow under operation tracking.
---@param project table? Project state used for development workflow context.
---@param opts? table Coverage options.
---@param callback? fun(result:table) Terminal coverage result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return unknown result Native coverage handle or synchronous result.
function M.coverage(project, opts, callback, notify)
    return development("coverage", project, opts, callback, notify)
end

return M
