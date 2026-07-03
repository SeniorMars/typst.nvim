local log = require("typst.core.log")
local async = require("typst.core.async")
local process = require("typst.core.process")

local M = {}
local uv = vim.uv or vim.loop

local next_id = 0
local active = {}
local retained = {}

-- Small lifecycle wrapper around vim.system handles.
--
-- The compiler, lint, viewer, and package layers all need the same guarantees:
-- terminal callbacks run once, cancellation escalates predictably, and failed
-- shutdowns remain visible as orphaned operations instead of disappearing.
---@class typst.Operation
---@field id number
---@field kind string
---@field state "starting"|"running"|"stopping"|"finished"|"orphaned-running"|"orphaned-retained"|nil
---@field pending boolean
---@field generation number|nil
---@field command string|nil
---@field cwd string|nil
---@field stdout string
---@field stderr string
---@field ok boolean|nil
---@field result table|nil
---@field reason string|nil
---@field message string|nil
---@field cancelled boolean|nil
---@field orphaned boolean|nil
---@field orphan_retained boolean|nil
---@field retained boolean|nil
---@field was_orphaned boolean|nil
---@field exited_after_orphan boolean|nil
---@field exited boolean|nil
---@field wait_timeout number|nil
---@field _callbacks table[]
---@field _cancel_callbacks table[]|nil
local Operation = {}
Operation.__index = Operation

-- Promote only stable result fields onto the pending handle. The raw result is
-- still stored on `operation.result`, but provider output must not overwrite
-- lifecycle methods or identity fields such as `cancel`, `finish`, `state`, or
-- `id`.
local public_result_fields = {
    ok = true,
    code = true,
    signal = true,
    stdout = true,
    stderr = true,
    reason = true,
    message = true,
    stopped = true,
    forced = true,
    spawn_failed = true,
    error = true,
    orphaned = true,
    orphan_retained = true,
    retained = true,
    was_orphaned = true,
    exited_after_orphan = true,
    exited = true,
}

local close_timer = async.close_timer
local schedule = async.schedule

local function copy_result_fields(operation, result)
    result = type(result) == "table" and result or {}
    operation.result = result

    for key, value in pairs(result) do
        if public_result_fields[key] then
            operation[key] = value
        end
    end

    if result.spawn_failed then
        operation.ok = false
        operation.reason = operation.reason or "spawn_failed"
        operation.message = operation.message or result.error or result.stderr
    elseif operation.timeout_reached then
        operation.ok = false
        operation.reason = "timeout"
        operation.message = operation.message
            or ("operation timed out after %dms"):format(
                operation.timeout_ms or 0
            )
    elseif operation.cancelled then
        operation.ok = false
        operation.reason = operation.reason or "cancelled"
        operation.message = operation.message or "operation was cancelled"
    elseif operation.ok == nil and type(result.code) == "number" then
        operation.ok = result.code == 0
    end
end

local function callbacks_snapshot(callbacks)
    local snapshot = {}
    for index, callback in ipairs(callbacks or {}) do
        snapshot[index] = callback
    end
    return snapshot
end

local function protected_callback(operation, callback)
    local ok, err = pcall(callback, operation)
    if not ok then
        log.add("warn", "operation callback failed", {
            id = operation.id,
            kind = operation.kind,
            error = err,
        })
    end
end

local function run_callbacks(operation)
    local callbacks = callbacks_snapshot(operation._callbacks)
    operation._callbacks = {}
    for _, callback in ipairs(callbacks) do
        protected_callback(operation, callback)
    end
end

local function cancel_settled(operation)
    return operation.state == "finished"
        or operation.state == "orphaned-retained"
end

local function protected_cancel_callback(operation, callback)
    local stopped = operation.stopped ~= false
    local ok, err = pcall(callback, stopped, operation)
    if not ok then
        log.add("warn", "operation cancel callback failed", {
            id = operation.id,
            kind = operation.kind,
            error = err,
        })
    end
end

local function add_cancel_callback(operation, callback)
    if type(callback) ~= "function" then
        return
    end
    if cancel_settled(operation) then
        protected_cancel_callback(operation, callback)
        return
    end
    operation._cancel_callbacks = operation._cancel_callbacks or {}
    operation._cancel_callbacks[#operation._cancel_callbacks + 1] = callback
end

local function drain_cancel_callbacks(operation)
    local callbacks = callbacks_snapshot(operation._cancel_callbacks)
    operation._cancel_callbacks = {}
    for _, callback in ipairs(callbacks) do
        protected_cancel_callback(operation, callback)
    end
end

local function terminal_state(state)
    return state == "finished"
end

local function wait_released_state(state)
    return state == "finished" or state == "orphaned-retained"
end

--- Register a callback to run when the process-backed operation really exits.
---
--- Retained orphans are removed from the active wait set, but they are not
--- "finished": the external process may still hold output files or other
--- resources. Cancellation callbacks passed to `_cancel()` settle at orphan
--- retention; `on_finish()` callbacks and destructive cleanup wait for the
--- actual process exit.
---
--- Duplicate and late callbacks are handled explicitly so one caller can safely
--- attach after completion and still observe terminal result.
---@param callback fun(operation:typst.Operation) Callback invoked with this operation after real process/provider completion.
---@return typst.Operation operation This operation, for chaining.
function Operation:on_finish(callback)
    if type(callback) ~= "function" then
        return self
    end

    -- Late subscribers are valid: APIs often return an Operation immediately and
    -- callers attach callbacks after inspecting the pending handle.
    if terminal_state(self.state) then
        protected_callback(self, callback)
    else
        self._callbacks[#self._callbacks + 1] = callback
    end

    return self
end

--- Mark operation as finished and flush lifecycle callbacks.
--- This finalizes timers, applies result fields, runs cleanup, and captures state in
--- one pass to keep cancellation and orphan handling consistent.
---@param result? table Terminal process/provider result fields to copy onto the operation.
---@return typst.Operation operation This operation after finalization.
function Operation:finish(result)
    if self.state == "finished" then
        return self
    end

    local was_orphaned = self.orphaned == true
    if was_orphaned then
        result = vim.tbl_extend("force", {
            exited = true,
            exited_after_orphan = true,
            orphaned = false,
            stopped = false,
            was_orphaned = true,
        }, type(result) == "table" and result or {})
        result.stopped = result.stopped == true
    end

    self.state = "finished"
    self.pending = false
    self.finished_at = uv.hrtime()
    if was_orphaned then
        self.exited = true
        self.exited_after_orphan = true
        self.was_orphaned = true
        self.orphaned = false
    end
    close_timer(self._timeout_timer)
    close_timer(self._kill_timer)
    close_timer(self._force_finish_timer)
    active[self.id] = nil
    retained[self.id] = nil

    copy_result_fields(self, result)
    drain_cancel_callbacks(self)

    if type(self.cleanup) == "function" then
        local ok, err = pcall(self.cleanup, self)
        if not ok then
            log.add("warn", "operation cleanup failed", {
                id = self.id,
                kind = self.kind,
                error = err,
            })
        end
    end

    run_callbacks(self)

    return self
end

--- Mark operation as orphaned when process termination is uncertain.
--- Keeps the handle in non-terminal state and stores diagnostic metadata so callers
--- can report failure without pretending the external process was stopped.
---@param result? table Failure metadata to merge into the orphaned operation result.
---@return typst.Operation operation This operation after orphan metadata is recorded.
function Operation:_orphan(result)
    if terminal_state(self.state) then
        return self
    end

    -- First mark the operation as live-orphaned so result tables, status, and
    -- leases can report failed cancellation without pretending the process was
    -- stopped. A later force-finish moves it out of the active wait set while
    -- preserving late-exit cleanup.
    self.state = "orphaned-running"
    self.pending = true
    self.orphaned = true
    self.orphaned_at = uv.hrtime()
    close_timer(self._timeout_timer)
    close_timer(self._kill_timer)
    close_timer(self._force_finish_timer)

    result = vim.tbl_extend("force", {
        code = 1,
        stdout = self.stdout or "",
        stderr = self.stderr or "",
        stopped = false,
        orphaned = true,
        reason = self.reason or "orphaned",
        message = "operation process could not be confirmed stopped",
    }, type(result) == "table" and result or {})

    copy_result_fields(self, result)
    log.add("warn", "operation process became orphaned", {
        id = self.id,
        kind = self.kind,
        error = self.error,
    })
    if type(self.on_cancel_failed) == "function" then
        local ok, err = pcall(self.on_cancel_failed, self)
        if not ok then
            log.add("warn", "operation cancel-failed callback failed", {
                id = self.id,
                kind = self.kind,
                error = err,
            })
        end
    end
    return self
end

--- Move an orphan out of the active wait set while preserving late-exit cleanup.
---
--- This is a stop-settlement state, not an operation-finish state. It drains
--- callbacks registered through `_cancel(..., callback)` so stop/restart callers
--- are not left pending, but intentionally does not run `on_finish()` callbacks
--- or cleanup hooks because the process is not confirmed stopped.
---@param result? table Failure metadata to merge into the retained orphan result.
---@return typst.Operation operation This operation after retention metadata is recorded.
function Operation:_retain_orphan(result)
    if terminal_state(self.state) then
        return self
    end

    if self.state ~= "orphaned-running" then
        self:_orphan(result)
    elseif type(result) == "table" then
        copy_result_fields(self, result)
    end

    if self.state == "orphaned-retained" then
        return self
    end

    self.state = "orphaned-retained"
    self.pending = false
    self.orphaned = true
    self.orphan_retained = true
    self.retained = true
    self.retained_at = uv.hrtime()
    close_timer(self._timeout_timer)
    close_timer(self._kill_timer)
    close_timer(self._force_finish_timer)
    active[self.id] = nil
    retained[self.id] = self

    copy_result_fields(
        self,
        vim.tbl_extend("force", {
            stopped = false,
            orphaned = true,
            orphan_retained = true,
            retained = true,
            reason = self.reason or "orphaned",
            message = self.message
                or "operation process retained after failed termination",
        }, type(result) == "table" and result or {})
    )

    log.add("warn", "operation orphan retained after failed termination", {
        id = self.id,
        kind = self.kind,
        error = self.error,
    })
    drain_cancel_callbacks(self)
    return self
end

--- Force close path for stalled cancellation.
--- Invoked by operation timeout escalation after repeated shutdown attempts.
---@param result? table Metadata explaining the forced finish reason.
---@private
function Operation:_force_finish(result)
    if terminal_state(self.state) then
        return
    end
    self:_retain_orphan(result or {
        code = 1,
        stdout = self.stdout or "",
        stderr = self.stderr or "",
        stopped = false,
        orphaned = true,
        reason = "orphaned",
        message = "operation did not exit after forced termination",
    })
end

--- Cancel an active operation using graceful then forceful process termination.
---
--- The optional callback observes stop settlement. It is called exactly once
--- when the process is confirmed stopped or when typst.nvim gives up and
--- retains the process as an orphan. `on_finish()` remains tied to the real
--- process exit and may run later for retained orphans.
---
--- Returns whether stop was achieved and the best-known result payload.
---@param opts? {reason?:string,term_signal?:number,kill_signal?:number,timeout_ms?:number,kill_timeout_ms?:number,wait?:boolean} Cancellation and signal timing overrides.
---@param callback? fun(stopped:boolean, result:table) Optional stop-settlement callback invoked after cancellation resolves or retention begins.
---@return boolean stopped True when the process is confirmed stopped or was already idle.
---@return table result Best-known cancellation result payload.
function Operation:_cancel(opts, callback)
    opts = vim.tbl_extend("force", {
        reason = "cancelled",
        term_signal = 15,
        kill_signal = 9,
        timeout_ms = 750,
        kill_timeout_ms = 750,
        wait = false,
    }, opts or {})

    if self.state == "finished" then
        if type(callback) == "function" then
            callback(true, { stopped = true, idle = true })
        end
        return true, { stopped = true, idle = true }
    end

    if
        self.state == "orphaned-running"
        or self.state == "orphaned-retained"
    then
        local result = {
            stopped = false,
            orphaned = true,
            orphan_retained = self.state == "orphaned-retained" or nil,
            retained = self.state == "orphaned-retained" or nil,
            error = self.error,
            message = self.message,
        }
        if type(callback) == "function" then
            callback(false, result)
        end
        return false, result
    end

    -- Cancellation is cooperative first and destructive second: TERM, optional
    -- KILL after a timeout, then orphan if the process still cannot be observed
    -- as stopped.
    self.cancelled = true
    self.reason = opts.reason
    self.state = "stopping"
    self.pending = true

    if type(self.on_cancel) == "function" then
        pcall(self.on_cancel, self, opts)
    end

    if not self.handle then
        self:finish({
            code = 1,
            stdout = self.stdout or "",
            stderr = self.stderr or "",
            stopped = true,
        })
        if type(callback) == "function" then
            callback(true, { stopped = true, idle = true })
        end
        return true, { stopped = true, idle = true }
    end

    if opts.wait then
        local ok, shutdown_result = process.shutdown(self.handle, opts)
        local stopped = ok
            and (not shutdown_result or shutdown_result.stopped ~= false)
        local payload = {
            code = ok and 0 or 1,
            stdout = self.stdout or "",
            stderr = self.stderr or "",
            stopped = stopped,
            forced = shutdown_result and shutdown_result.forced,
            error = shutdown_result and shutdown_result.error,
        }
        if not stopped then
            payload = vim.tbl_extend("force", payload, {
                orphaned = true,
                reason = self.reason or "cancelled",
                message = shutdown_result and shutdown_result.error
                    or "operation did not stop cleanly",
            })
        end

        if self.state ~= "finished" then
            if stopped then
                self:finish(payload)
            else
                self:_retain_orphan(payload)
            end
        end
        if type(callback) == "function" then
            callback(stopped, payload)
        end
        return stopped, payload
    end

    local ok, err = process.kill(self.handle, opts.term_signal)
    if not ok then
        self:_retain_orphan({
            code = 1,
            stdout = self.stdout or "",
            stderr = self.stderr or tostring(err or ""),
            stopped = false,
            orphaned = true,
            error = err,
            reason = self.reason or "cancelled",
            message = "operation SIGTERM failed",
        })
        if type(callback) == "function" then
            callback(false, { stopped = false, orphaned = true, error = err })
        end
        return false, { stopped = false, orphaned = true, error = err }
    end

    local function force_finish_later()
        if (opts.kill_timeout_ms or 0) <= 0 then
            self:_retain_orphan()
            return
        end

        self._force_finish_timer = uv.new_timer()
        self._force_finish_timer:start(opts.kill_timeout_ms, 0, function()
            schedule(function()
                self:_retain_orphan()
            end)
        end)
    end

    local function escalate()
        if self.state == "finished" then
            return
        end
        local killed, kill_err = process.kill(self.handle, opts.kill_signal)
        if not killed then
            self:_retain_orphan({
                code = 1,
                stdout = self.stdout or "",
                stderr = self.stderr or tostring(kill_err or ""),
                stopped = false,
                forced = true,
                orphaned = true,
                error = kill_err,
                reason = self.reason or "cancelled",
                message = "operation force kill failed",
            })
            return
        end
        force_finish_later()
    end

    add_cancel_callback(self, callback)

    if (opts.timeout_ms or 0) <= 0 then
        escalate()
    else
        self._kill_timer = uv.new_timer()
        self._kill_timer:start(opts.timeout_ms, 0, function()
            schedule(escalate)
        end)
    end

    return false, { pending = true, stopping = true, stopped = false }
end

--- Mark operation as timed out and begin cancellation flow.
--- This sets timeout metadata before reusing existing cancel path.
function Operation:timeout()
    if terminal_state(self.state) then
        return
    end

    self.timeout_reached = true
    self:_cancel({
        reason = "timeout",
        timeout_ms = 0,
        kill_timeout_ms = 250,
        wait = false,
    })
end

--- Block until the operation reaches terminal state, or timeout elapses.
---@param timeout_ms? number Maximum milliseconds to wait before returning the still-pending operation.
---@return typst.Operation operation This operation after waiting.
function Operation:wait(timeout_ms)
    if wait_released_state(self.state) then
        return self
    end

    vim.wait(timeout_ms or 10000, function()
        return wait_released_state(self.state)
    end, 10, false)
    return self
end

local function next_operation_id()
    next_id = next_id + 1
    return next_id
end

--- Create a pending operation record without starting a process.
---@param kind string Operation category used for logs and active-operation tracking.
---@param opts? table Operation metadata and lifecycle callbacks.
---@return typst.Operation operation Pending operation registered in active state.
function M.new(kind, opts)
    opts = opts or {}
    local operation = setmetatable({
        id = next_operation_id(),
        kind = kind or "operation",
        state = "starting",
        pending = true,
        generation = opts.generation,
        command = opts.command,
        cwd = opts.cwd,
        stdout = "",
        stderr = "",
        cleanup = opts.cleanup,
        on_cancel = opts.on_cancel,
        on_cancel_failed = opts.on_cancel_failed,
        _callbacks = {},
        _cancel_callbacks = {},
    }, Operation)
    operation.cancel = function(first, second, third)
        if first == operation then
            return operation:_cancel(second, third)
        end
        return operation:_cancel(first, second)
    end

    active[operation.id] = operation
    return operation
end

--- Spawn a process and bind it to a managed operation.
---@param kind string Operation category used for logs and active-operation tracking.
---@param command string[] Command argv passed to `vim.system`.
---@param opts? table Process options passed to `typst.core.process.spawn`.
---@param handlers? table Operation/process lifecycle callbacks and timeout controls.
---@return typst.Operation operation Running operation with process handle and cancellation API.
function M.run(kind, command, opts, handlers)
    opts = opts or {}
    handlers = handlers or {}

    local operation = M.new(kind, {
        command = command,
        cwd = opts.cwd,
        generation = handlers.generation,
        cleanup = handlers.cleanup,
        on_cancel = handlers.on_cancel,
        on_cancel_failed = handlers.on_cancel_failed,
    })

    if type(handlers.on_finish) == "function" then
        operation:on_finish(handlers.on_finish)
    end

    local proc_opts = vim.tbl_extend("force", opts, {})
    local timeout_ms = tonumber(handlers.timeout_ms or opts.timeout_ms)
    proc_opts.timeout_ms = nil

    operation.state = "running"
    operation.handle = process.spawn(command, proc_opts, {
        on_exit = function(result)
            if handlers.schedule == false then
                operation:finish(result)
            else
                schedule(function()
                    operation:finish(result)
                end)
            end
        end,
        on_spawn_error = handlers.on_spawn_error,
    })

    if timeout_ms and timeout_ms > 0 then
        operation.timeout_ms = timeout_ms
        operation._timeout_timer = uv.new_timer()
        operation._timeout_timer:start(timeout_ms, 0, function()
            schedule(function()
                operation:timeout()
            end)
        end)
    end

    return operation
end

--- Attach a managed operation to an existing result table.
---@param result table Result table that receives handle, operation, and cancel fields.
---@param kind string Operation category used for logs and active-operation tracking.
---@param command string[] Command argv passed to `vim.system`.
---@param opts? table Process options passed to `typst.core.process.spawn`.
---@param handlers? table Operation/process lifecycle callbacks and timeout controls.
---@return typst.Operation operation Running operation attached to `result`.
function M.attach(result, kind, command, opts, handlers)
    result = result or {}
    handlers = handlers or {}

    ---@type fun(operation:typst.Operation, result:table)|nil
    local on_finish = handlers.on_finish
    ---@type fun(result:table, operation:typst.Operation, cancel_opts:table)|nil
    local on_cancel = handlers.on_cancel
    ---@type fun(operation:typst.Operation)|nil
    local on_cancel_failed = handlers.on_cancel_failed
    handlers.on_cancel = function(operation, cancel_opts)
        result.cancel_requested = true
        result.cancelled = true
        result.pending = true
        result.ok = false
        result.state = "cancelling"
        result.reason = cancel_opts.reason or "cancelled"
        if type(on_cancel) == "function" then
            on_cancel(result, operation, cancel_opts)
        end
    end
    handlers.on_cancel_failed = function(operation)
        result.pending = true
        result.ok = false
        result.state = "orphaned"
        result.reason = operation.reason or "child_orphaned"
        result.message = operation.message
            or "operation process could not be confirmed stopped"
        if type(on_cancel_failed) == "function" then
            on_cancel_failed(operation)
        end
    end
    handlers.on_finish = function(operation)
        result.handle = operation.handle
        result.operation = operation
        if operation.cancelled then
            result.ok = false
            result.pending = false
            result.reason = result.reason or operation.reason or "cancelled"
            result.state = operation.was_orphaned and "orphaned" or "cancelled"
        end
        if type(on_finish) == "function" then
            on_finish(operation, result)
        end
    end

    local operation = M.run(kind, command, opts, handlers)
    result.operation = operation
    result.handle = operation.handle
    result.cancel = function(cancel_opts, callback)
        return operation:_cancel(cancel_opts, callback)
    end
    return operation
end

--- Return currently active operations keyed by operation id.
---@return table<number, typst.Operation> operations Snapshot of active operations.
function M.active()
    local out = {}
    for id, operation in pairs(active) do
        out[id] = operation
    end
    return out
end

--- Return retained orphan operations keyed by operation id.
---@return table<number, typst.Operation> operations Snapshot of retained orphan operations.
function M.retained()
    local out = {}
    for id, operation in pairs(retained) do
        out[id] = operation
    end
    return out
end

--- Cancel every active operation.
---@param opts? table Cancellation options forwarded to each operation.
---@return boolean ok True when every active operation reported stopped.
---@return table[] results Cancellation result payloads.
function M.cancel_all(opts)
    local ok = true
    local results = {}
    local pending = vim.tbl_values(active)
    for _, operation in ipairs(pending) do
        local stopped, result = operation:_cancel(opts)
        results[#results + 1] = result
        if not stopped then
            ok = false
        end
    end
    return ok, results
end

--- Run a provider-style function and deliver exactly one terminal notification.
---
--- Provider adapters may invoke their callback synchronously before returning a
--- pending handle. This helper preserves the returned handle for the caller
--- while still finalizing the early result once the return value is known.
---@param run fun(callback:function):any Function invoked with a terminal-result callback.
---@param opts? {notify_result?:fun(result:any),notify?:fun(message:string,level?:integer),start_message?:string,callback?:fun(result:any)}
---@return any result The synchronous result or pending handle returned by `run`.
function M.notify_result(run, opts)
    opts = opts or {}
    local notify_result = opts.notify_result or function() end
    local notify = opts.notify or function() end
    local user_callback = opts.callback
    local result
    local result_set = false
    local queued_result = nil
    local completed = false

    local function finish(done)
        if completed then
            return
        end
        completed = true
        notify_result(done)
        if type(user_callback) == "function" then
            local ok, err = pcall(user_callback, done)
            if not ok then
                log.add("warn", "operation result callback failed", {
                    error = err,
                })
            end
        end
    end

    result = run(function(done)
        if not result_set then
            queued_result = done
            return
        end
        finish(done)
    end)
    result_set = true

    if queued_result ~= nil then
        finish(queued_result)
        return result
    end

    if type(result) == "table" and result.pending then
        if opts.start_message and result.reason == nil then
            notify(opts.start_message)
        end
        return result
    end

    finish(result)
    return result
end

M.Operation = Operation

return M
