local M = {}
local log = require("typst.core.log")
local uv = vim.uv or vim.loop
local DEFAULT_TERM_TIMEOUT_MS = 750
local DEFAULT_KILL_TIMEOUT_MS = 750

-- Process helpers keep external Typst tools detached from Neovim but still
-- stoppable as a tree. This matters for wrappers that spawn child processes
-- and for VimLeavePre cleanup.

local function is_windows()
    if M._force_windows ~= nil then
        return M._force_windows == true
    end
    return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

local function spawn_error_result(command, opts, err)
    return {
        code = 1,
        signal = nil,
        stdout = "",
        stderr = tostring(err),
        error = tostring(err),
        spawn_failed = true,
        command = command,
        cwd = opts and opts.cwd or nil,
    }
end

local function spawn_error_handle(result)
    return {
        _typst_spawn_error = result,
        exited = true,
        result = result,
        is_closing = function()
            return true
        end,
        kill = function()
            return true
        end,
        wait = function()
            return result
        end,
    }
end

local ProcessHandle = {}
ProcessHandle.__index = ProcessHandle

local function raw_field(raw, key)
    local ok, value = pcall(function()
        return raw and raw[key] or nil
    end)
    if ok then
        return value
    end
    return nil
end

local function wrap_handle(raw, on_wait_result)
    local handle = {
        _typst_process_handle = true,
        raw = raw,
        pid = raw_field(raw, "pid"),
        exited = false,
        result = nil,
        _on_wait_result = on_wait_result,
    }

    return setmetatable(handle, ProcessHandle)
end

function ProcessHandle:is_closing()
    if self.exited then
        return true
    end

    local raw = self.raw
    local raw_is_closing = raw_field(raw, "is_closing")
    if type(raw_is_closing) == "function" then
        local ok, closing = pcall(function()
            return raw_is_closing(raw)
        end)
        return ok and closing == true
    end

    return false
end

function ProcessHandle:kill(signal)
    local raw = self.raw
    local raw_kill = raw_field(raw, "kill")
    if type(raw_kill) ~= "function" then
        return false, "process handle is unavailable"
    end
    return raw_kill(raw, signal)
end

function ProcessHandle.wait(self, timeout_ms)
    if self.exited then
        return self.result
    end

    local raw = self.raw
    local raw_wait = raw_field(raw, "wait")
    if type(raw_wait) ~= "function" then
        return nil
    end

    local ok, result = pcall(function()
        return raw_wait(raw, timeout_ms)
    end)
    if not ok then
        return nil, result
    end

    if type(result) == "table" then
        if type(self._on_wait_result) == "function" then
            self._on_wait_result(result)
        else
            self.exited = true
            self.result = result
        end
    end

    return result
end

local function pack_returns(...)
    return {
        n = select("#", ...),
        ...,
    }
end

--- Spawn an external process with guarded exit and spawn-error callbacks.
---@param command string|string[] Command passed to `vim.system`.
---@param opts? table Process options; detached by default.
---@param handlers? {on_exit?:fun(result:table),on_spawn_error?:fun(result:table),cleanup?:fun(result:table)} Lifecycle callbacks protected from duplicate finish calls.
---@return table handle Process handle, or spawn-error shim with `kill`, `wait`, and `is_closing`.
function M.spawn(command, opts, handlers)
    handlers = handlers or {}
    opts = vim.tbl_extend("force", opts or {}, {
        detach = opts == nil or opts.detach ~= false,
    })

    local finished = false
    local handle
    local early_result
    local function finish(result)
        if finished then
            return
        end
        finished = true

        if handle then
            handle.exited = true
            handle.result = result
        else
            early_result = result
        end

        if type(handlers.cleanup) == "function" then
            pcall(handlers.cleanup, result)
        end
        if type(handlers.on_exit) == "function" then
            local ok, err = pcall(handlers.on_exit, result)
            if not ok then
                log.add("warn", "process exit callback failed", {
                    command = command,
                    cwd = opts and opts.cwd or nil,
                    error = err,
                })
            end
        end
    end

    local ok, raw = pcall(vim.system, command, opts, finish)
    if ok then
        handle = wrap_handle(raw, finish)
        if early_result then
            handle.exited = true
            handle.result = early_result
        end
        return handle
    end

    local result = spawn_error_result(command, opts, raw)
    if type(handlers.on_spawn_error) == "function" then
        pcall(handlers.on_spawn_error, result)
    end
    vim.schedule(function()
        finish(result)
    end)
    return spawn_error_handle(result)
end

--- Spawn a process and route its terminal result to one callback.
---@param command string|string[] Command passed to `vim.system`.
---@param opts? table Process options forwarded to `spawn`.
---@param on_exit? fun(result:table) Callback invoked with the terminal result.
---@return table handle Process handle or spawn-error shim.
function M.system(command, opts, on_exit)
    return M.spawn(command, opts, {
        on_exit = on_exit,
    })
end

local function kill_group(handle, signal)
    if
        is_windows()
        or type(handle) ~= "table"
        or type(handle.pid) ~= "number"
    then
        return false, "process groups are unavailable"
    end

    -- On Unix, libuv accepts a negative pid to signal the process group. Windows
    -- needs taskkill /T instead, handled in terminate_tree().
    local ok, result, err = pcall(uv.kill, -handle.pid, signal)
    if ok and result == 0 then
        return true
    end

    return false, err or result or "process group signal failed"
end

local function kill_process(handle, signal)
    if not handle or type(handle.kill) ~= "function" then
        return false, "process handle is unavailable"
    end

    local returned = pack_returns(pcall(handle.kill, handle, signal))
    if not returned[1] then
        return false, returned[2]
    end

    if returned.n == 1 then
        return true
    end

    local result = returned[2]
    local err = returned[3]
    if result == false or result == nil then
        return false, err or "kill failed"
    end

    if type(result) == "number" and result ~= 0 then
        return false, err or result
    end

    return true
end

--- Signal a process, preferring process-group termination on Unix.
---@param handle table|nil Process handle returned by `vim.system`.
---@param signal? integer Signal number to send.
---@return boolean ok True when a process or group was targeted successfully.
---@return string|nil error Error message when no signal path succeeded.
---@return string|nil mode Signal target mode such as `group` or `process`.
---@return string|nil fallback_error Process-group error when direct process fallback succeeded.
function M.kill(handle, signal)
    local group_ok, group_err = kill_group(handle, signal)
    if group_ok then
        return true, nil, "group"
    end

    local process_ok, process_err = kill_process(handle, signal)
    if process_ok then
        return true, nil, "process", group_err
    end

    return false, process_err or group_err
end

local function is_closing(handle)
    if type(handle) == "table" and handle.exited == true then
        return true
    end

    if not handle or type(handle.is_closing) ~= "function" then
        return false
    end

    local ok, closing = pcall(function()
        return handle:is_closing()
    end)
    return ok and closing == true
end

local function wait_once(handle, timeout_ms)
    if not handle or type(handle.wait) ~= "function" then
        return false, nil
    end

    local ok, result = pcall(function()
        return handle.wait(handle, timeout_ms)
    end)
    if ok and type(result) == "table" then
        return true, result
    end
    return false, nil
end

local function wait_result_forced(result)
    return type(result) == "table"
        and (result.signal == 9 or result.code == 124)
end

local function should_wait_once(handle, opts)
    if opts.accept_forced_wait == true then
        return true
    end
    -- Do not call the raw SystemObj wait method for typst.nvim-owned handles
    -- during graceful shutdown. A finite wait timeout force-kills the raw
    -- process; the graceful phase should let the libuv exit callback update
    -- wrapper state while vim.wait() pumps the event loop. After forced tree
    -- kill, the raw wait method may collect the terminal result.
    return not (
        type(handle) == "table" and handle._typst_process_handle == true
    )
end

local function wait_for_exit(handle, timeout_ms, opts)
    opts = opts or {}
    if is_closing(handle) then
        return true, false, nil
    end

    timeout_ms = math.max(0, timeout_ms or 0)
    if should_wait_once(handle, opts) then
        local waited, result = wait_once(handle, timeout_ms)
        if waited then
            local forced = wait_result_forced(result)
            if forced and opts.accept_forced_wait ~= true then
                return false, true, result
            end
            return true, forced, result
        end
    end

    if timeout_ms == 0 then
        return is_closing(handle), false, nil
    end

    local ok = vim.wait(timeout_ms, function()
        return is_closing(handle)
    end, 10, false)
    return ok == true or is_closing(handle), false, nil
end

local function windows_taskkill(handle, force)
    if not handle or type(handle.pid) ~= "number" then
        return false, "process id is unavailable"
    end

    local command = { "taskkill", "/PID", tostring(handle.pid), "/T" }
    if force then
        command[#command + 1] = "/F"
    end

    local ok, system =
        pcall(vim.system, command, { text = true, detach = false })
    if not ok then
        return false, system
    end

    local wait_ok, result = pcall(function()
        return system:wait(1000)
    end)
    if not wait_ok then
        return false, result
    end

    if type(result) == "table" and result.code == 0 then
        return true
    end

    return false,
        result and (result.stderr or result.stdout or result.code)
            or "taskkill failed"
end

local function terminate_tree(handle, signal)
    if is_windows() then
        local ok, err = windows_taskkill(handle, signal == 9)
        if ok then
            return true,
                nil,
                signal == 9 and "windows-tree-forced" or "windows-tree"
        end

        local process_ok, process_err = kill_process(handle, signal)
        if process_ok then
            return true, nil, "process", err
        end

        return false, process_err or err
    end

    return M.kill(handle, signal)
end

--- Request graceful process shutdown, then force termination if needed.
---@param handle table Process handle returned by `vim.system`.
---@param opts? {term_signal?:integer,kill_signal?:integer,timeout_ms?:integer,kill_timeout_ms?:integer} Shutdown signal and wait-time controls.
---@return boolean stopped True when the process is confirmed stopped or already idle.
---@return table result Stop metadata used by lifecycle cleanup.
function M.shutdown(handle, opts)
    opts = vim.tbl_extend("force", {
        term_signal = 15,
        kill_signal = 9,
        timeout_ms = DEFAULT_TERM_TIMEOUT_MS,
        kill_timeout_ms = DEFAULT_KILL_TIMEOUT_MS,
    }, opts or {})

    if not handle or is_closing(handle) then
        return true, { stopped = true, idle = true }
    end

    -- Try a graceful tree termination first, then force-kill the tree if it does
    -- not exit within the configured timeout. The returned metadata is used by
    -- lifecycle reset to decide whether project resources can be discarded.
    local ok, err, mode, fallback = terminate_tree(handle, opts.term_signal)
    if not ok then
        return false,
            {
                stopped = false,
                error = err,
            }
    end

    local exited, wait_forced = wait_for_exit(handle, opts.timeout_ms)
    if exited then
        return true,
            {
                stopped = true,
                forced = wait_forced == true,
                signal_target = mode,
                fallback_error = fallback,
            }
    end

    local killed, kill_err, kill_mode, kill_fallback =
        terminate_tree(handle, opts.kill_signal)
    if not killed then
        return false,
            {
                stopped = false,
                forced = true,
                signal_target = mode,
                fallback_error = fallback,
                error = kill_err,
            }
    end

    exited = wait_for_exit(handle, opts.kill_timeout_ms, {
        accept_forced_wait = true,
    })
    return exited,
        {
            stopped = exited,
            forced = true,
            signal_target = mode,
            force_signal_target = kill_mode,
            fallback_error = fallback,
            force_fallback_error = kill_fallback,
            error = exited and nil
                or "process did not exit after forced termination",
        }
end

return M
