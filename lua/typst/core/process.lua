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
    local function finish(result)
        if finished then
            return
        end
        finished = true

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

    local ok, handle = pcall(vim.system, command, opts, finish)
    if ok then
        return handle
    end

    local result = spawn_error_result(command, opts, handle)
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
    if not handle or type(handle.is_closing) ~= "function" then
        return false
    end

    local ok, closing = pcall(function()
        return handle:is_closing()
    end)
    return ok and closing == true
end

local function wait_for_exit(handle, timeout_ms)
    if is_closing(handle) then
        return true
    end

    timeout_ms = math.max(0, timeout_ms or 0)
    if timeout_ms == 0 then
        return is_closing(handle)
    end

    local ok = vim.wait(timeout_ms, function()
        return is_closing(handle)
    end, 10, false)
    return ok == true or is_closing(handle)
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

    if wait_for_exit(handle, opts.timeout_ms) then
        return true,
            {
                stopped = true,
                forced = false,
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

    local exited = wait_for_exit(handle, opts.kill_timeout_ms)
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
