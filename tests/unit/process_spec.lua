local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local process = require("typst.core.process")
local uv = vim.uv or vim.loop

local original_kill = uv.kill
local original_system = vim.system
local original_force_windows = process._force_windows
local kill_calls = {}
local native_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

local ok, err = xpcall(function()
    local direct_kill_calls = 0
    local no_return_handle = {
        kill = function(_, signal)
            direct_kill_calls = direct_kill_calls + 1
            assert(signal == 15, "direct kill should pass the requested signal")
        end,
    }
    local killed = assert(
        process.kill(no_return_handle, 15),
        "kill should accept handle methods that return no values on success"
    )
    assert(killed == true, "direct no-return kill should report success")
    assert(direct_kill_calls == 1, "direct no-return kill should call handle")

    local false_return_handle = {
        kill = function()
            return false, "direct kill denied"
        end,
    }
    local failed, kill_err = process.kill(false_return_handle, 15)
    assert(
        failed == false and kill_err == "direct kill denied",
        "kill should report explicit false returns as failures"
    )

    local nil_return_handle = {
        kill = function()
            return nil, "direct kill nil error"
        end,
    }
    failed, kill_err = process.kill(nil_return_handle, 15)
    assert(
        failed == false and kill_err == "direct kill nil error",
        "kill should report explicit nil,error returns as failures"
    )

    if not native_windows then
        uv.kill = function(pid, signal)
            kill_calls[#kill_calls + 1] = { pid = pid, signal = signal }
            return 0
        end

        local checks = 0
        local graceful = {
            pid = 41001,
            closed = false,
        }

        function graceful:is_closing()
            checks = checks + 1
            if checks >= 2 then
                self.closed = true
            end
            return self.closed
        end

        local stopped, result =
            process.shutdown(graceful, { timeout_ms = 50, kill_timeout_ms = 1 })
        assert(
            stopped,
            "shutdown should report success when the process exits after SIGTERM"
        )
        assert(
            result and result.forced == false,
            "graceful shutdown should not report forced termination"
        )
        assert(#kill_calls == 1, "graceful shutdown should not send SIGKILL")
        assert(
            kill_calls[1].pid == -41001 and kill_calls[1].signal == 15,
            "shutdown should SIGTERM the process group"
        )

        kill_calls = {}
        local stubborn = {
            pid = 41002,
        }

        function stubborn:is_closing()
            return false
        end

        stopped, result =
            process.shutdown(stubborn, { timeout_ms = 1, kill_timeout_ms = 1 })
        assert(
            not stopped,
            "shutdown should report failure when the process ignores forced termination"
        )
        assert(
            result and result.forced == true,
            "stubborn shutdown should report forced termination"
        )
        assert(
            #kill_calls == 2,
            "stubborn shutdown should send SIGTERM then SIGKILL"
        )
        assert(
            kill_calls[1].pid == -41002 and kill_calls[1].signal == 15,
            "shutdown should SIGTERM the group first"
        )
        assert(
            kill_calls[2].pid == -41002 and kill_calls[2].signal == 9,
            "shutdown should SIGKILL the group after timeout"
        )
    end

    process._force_windows = true
    local taskkill_calls = {}
    local graceful_windows = {
        pid = 42001,
        closed = false,
    }

    function graceful_windows:is_closing()
        return self.closed
    end

    vim.system = function(command)
        taskkill_calls[#taskkill_calls + 1] = command
        graceful_windows.closed = true
        return {
            wait = function()
                return { code = 0 }
            end,
        }
    end

    local stopped, result = process.shutdown(
        graceful_windows,
        { timeout_ms = 1, kill_timeout_ms = 1 }
    )
    assert(
        stopped,
        "Windows shutdown should succeed after taskkill exits the process tree"
    )
    assert(
        result.signal_target == "windows-tree",
        "Windows shutdown should report taskkill tree termination"
    )
    assert(
        table.concat(taskkill_calls[1], " ") == "taskkill /PID 42001 /T",
        "Windows shutdown should use taskkill /T"
    )

    taskkill_calls = {}
    local forced_windows = {
        pid = 42002,
        closed = false,
    }

    function forced_windows:is_closing()
        return self.closed
    end

    vim.system = function(command)
        taskkill_calls[#taskkill_calls + 1] = command
        if command[#command] == "/F" then
            forced_windows.closed = true
        end
        return {
            wait = function()
                return { code = 0 }
            end,
        }
    end

    stopped, result = process.shutdown(
        forced_windows,
        { timeout_ms = 1, kill_timeout_ms = 20 }
    )
    assert(
        stopped,
        "Windows shutdown should force taskkill after the graceful timeout"
    )
    assert(
        result.forced == true,
        "Windows forced shutdown should report forced termination"
    )
    assert(
        result.force_signal_target == "windows-tree-forced",
        "Windows forced shutdown should report forced taskkill"
    )
    assert(
        table.concat(taskkill_calls[1], " ") == "taskkill /PID 42002 /T",
        "Windows shutdown should try graceful tree termination first"
    )
    assert(
        table.concat(taskkill_calls[2], " ") == "taskkill /PID 42002 /T /F",
        "Windows shutdown should force the process tree after timeout"
    )
end, debug.traceback)

uv.kill = original_kill
vim.system = original_system
process._force_windows = original_force_windows

if not ok then
    error(err)
end

local original_spawn_system = vim.system
local callbacks = 0
local cleanups = 0
local spawn_errors = 0

ok, err = xpcall(function()
    vim.system = function()
        error("spawn boom")
    end

    local handle = process.spawn({ "missing-executable" }, { cwd = root }, {
        on_spawn_error = function(result)
            spawn_errors = spawn_errors + 1
            assert(result.spawn_failed, "spawn-error result should be marked")
        end,
        cleanup = function(result)
            cleanups = cleanups + 1
            assert(
                result.spawn_failed,
                "cleanup should receive the spawn-error result"
            )
        end,
        on_exit = function(result)
            callbacks = callbacks + 1
            assert(
                result.spawn_failed,
                "terminal callback should receive the spawn-error result"
            )
            assert(
                result.code == 1,
                "spawn failure should be reported as failed"
            )
            assert(result.cwd == root, "spawn failure should preserve cwd")
        end,
    })

    assert(
        handle:is_closing(),
        "spawn-error handle should behave like a closed process"
    )
    assert(
        handle:wait().spawn_failed,
        "spawn-error handle wait should return the spawn-error result"
    )
    assert(
        spawn_errors == 1,
        "spawn-error callback should run immediately once"
    )
    assert(
        vim.wait(1000, function()
            return callbacks == 1 and cleanups == 1
        end, 10),
        "spawn-error terminal callback did not run"
    )
    assert(callbacks == 1, "spawn-error terminal callback should run once")
    assert(cleanups == 1, "spawn-error cleanup should run once")
end, debug.traceback)

vim.system = original_spawn_system

if not ok then
    error(err)
end

vim.cmd("qa!")
