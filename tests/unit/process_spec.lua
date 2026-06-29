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

        kill_calls = {}
        local wait_calls = 0
        local wait_only = {
            pid = 41003,
            wait = function(_, timeout_ms)
                wait_calls = wait_calls + 1
                assert(
                    timeout_ms == 50,
                    "shutdown should pass timeout to handle wait"
                )
                return { code = 0 }
            end,
        }

        stopped, result = process.shutdown(
            wait_only,
            { timeout_ms = 50, kill_timeout_ms = 1 }
        )
        assert(
            stopped,
            "shutdown should use wait() when is_closing() is unavailable"
        )
        assert(
            result and result.forced == false,
            "wait()-confirmed shutdown should be graceful"
        )
        assert(wait_calls == 1, "shutdown should wait once for exit")
        assert(
            #kill_calls == 1
                and kill_calls[1].pid == -41003
                and kill_calls[1].signal == 15,
            "wait-only shutdown should still signal the process group first"
        )

        kill_calls = {}
        local timeout_wait_calls = 0
        local wait_timeout = {
            pid = 41004,
            wait = function(_, timeout_ms)
                timeout_wait_calls = timeout_wait_calls + 1
                if timeout_wait_calls == 1 then
                    assert(
                        timeout_ms == 50,
                        "graceful shutdown should pass timeout to wait"
                    )
                    return { code = 124, signal = 9 }
                end
                assert(
                    timeout_ms == 25,
                    "forced shutdown should pass kill timeout to wait"
                )
                return { code = 0, signal = 9 }
            end,
        }

        stopped, result = process.shutdown(wait_timeout, {
            timeout_ms = 50,
            kill_timeout_ms = 25,
        })
        assert(stopped, "shutdown should confirm stop after forced tree kill")
        assert(
            result and result.forced == true,
            "wait timeout should not be reported as graceful shutdown"
        )
        assert(
            timeout_wait_calls == 2,
            "shutdown should wait again after forced tree kill"
        )
        assert(
            #kill_calls == 2,
            "wait timeout should send SIGTERM then SIGKILL"
        )
        assert(
            kill_calls[1].pid == -41004 and kill_calls[1].signal == 15,
            "wait-timeout shutdown should SIGTERM the group first"
        )
        assert(
            kill_calls[2].pid == -41004 and kill_calls[2].signal == 9,
            "wait-timeout shutdown should SIGKILL the group after timeout"
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
local original_spawn_kill = uv.kill
local wait_callbacks = 0
local wait_cleanups = 0

ok, err = xpcall(function()
    vim.system = function()
        return {
            pid = 43001,
            wait = function()
                return { code = 0, stdout = "done" }
            end,
            kill = function()
                return true
            end,
        }
    end

    local handle = process.spawn({ "fake" }, {}, {
        cleanup = function(result)
            wait_cleanups = wait_cleanups + 1
            assert(result.code == 0, "wait cleanup should receive result")
        end,
        on_exit = function(result)
            wait_callbacks = wait_callbacks + 1
            assert(result.code == 0, "wait callback should receive result")
        end,
    })

    assert(
        not handle:is_closing(),
        "fresh process wrapper should not be closed before exit"
    )
    local result = handle:wait(0)
    assert(result and result.code == 0, "wrapper wait should return result")
    assert(handle:is_closing(), "wrapper wait should mark handle exited")
    assert(
        handle.result and handle.result.stdout == "done",
        "wrapper should retain terminal result"
    )
    assert(wait_callbacks == 1, "wrapper wait should finish callbacks once")
    assert(wait_cleanups == 1, "wrapper wait should finish cleanup once")
    handle:wait(0)
    assert(
        wait_callbacks == 1 and wait_cleanups == 1,
        "repeated wrapper wait should not duplicate lifecycle callbacks"
    )

    if not native_windows then
        local shutdown_waits = 0
        local shutdown_callbacks = 0
        local shutdown_cleanups = 0
        local shutdown_closing_checks = 0
        local shutdown_exited = false
        kill_calls = {}
        uv.kill = function(pid, signal)
            kill_calls[#kill_calls + 1] = { pid = pid, signal = signal }
            return 0
        end
        vim.system = function(_, _, on_exit)
            return {
                pid = 43002,
                is_closing = function()
                    shutdown_closing_checks = shutdown_closing_checks + 1
                    if shutdown_closing_checks >= 2 and not shutdown_exited then
                        shutdown_exited = true
                        on_exit({ code = 0, stdout = "shutdown done" })
                    end
                    return shutdown_exited
                end,
                wait = function(_, timeout_ms)
                    shutdown_waits = shutdown_waits + 1
                    assert(
                        timeout_ms == 1,
                        "wrapped shutdown should only wait after forced kill"
                    )
                    return { code = 0, stdout = "forced shutdown done" }
                end,
                kill = function()
                    return true
                end,
            }
        end

        local shutdown_handle = process.spawn({ "fake-shutdown" }, {}, {
            cleanup = function(result)
                shutdown_cleanups = shutdown_cleanups + 1
                assert(
                    result.stdout == "shutdown done",
                    "shutdown wrapper cleanup should receive wait result"
                )
            end,
            on_exit = function(result)
                shutdown_callbacks = shutdown_callbacks + 1
                assert(
                    result.code == 0,
                    "shutdown wrapper callback should receive wait result"
                )
            end,
        })
        local stopped, shutdown_result = process.shutdown(shutdown_handle, {
            timeout_ms = 25,
            kill_timeout_ms = 1,
        })
        assert(
            stopped,
            "shutdown should use wrapper exit state to confirm graceful exit"
        )
        assert(
            shutdown_result and shutdown_result.forced == false,
            "wrapper callback-confirmed shutdown should be graceful"
        )
        assert(
            shutdown_waits == 0,
            "graceful wrapped shutdown should not call SystemObj:wait(timeout)"
        )
        assert(
            shutdown_callbacks == 1 and shutdown_cleanups == 1,
            "shutdown wrapper callback should finish lifecycle callbacks once"
        )
        assert(
            shutdown_handle.exited
                and shutdown_handle.result
                and shutdown_handle.result.stdout == "shutdown done",
            "shutdown should retain wrapper callback result"
        )
        assert(
            #kill_calls == 1
                and kill_calls[1].pid == -43002
                and kill_calls[1].signal == 15,
            "shutdown should signal the wrapped process group before waiting"
        )

        local wrapped_timeout_waits = 0
        local wrapped_timeout_callbacks = 0
        kill_calls = {}
        vim.system = function()
            return {
                pid = 43003,
                wait = function(_, timeout_ms)
                    wrapped_timeout_waits = wrapped_timeout_waits + 1
                    assert(
                        timeout_ms == 1,
                        "wrapped timeout should wait only after forced tree kill"
                    )
                    return { code = 124, signal = 9 }
                end,
                kill = function()
                    return true
                end,
            }
        end

        local wrapped_timeout_handle = process.spawn(
            { "fake-shutdown-timeout" },
            {},
            {
                on_exit = function(result)
                    wrapped_timeout_callbacks = wrapped_timeout_callbacks + 1
                    assert(
                        result.code == 124,
                        "wrapped timeout callback should receive wait result"
                    )
                end,
            }
        )
        stopped, shutdown_result = process.shutdown(wrapped_timeout_handle, {
            timeout_ms = 25,
            kill_timeout_ms = 1,
        })
        assert(
            stopped,
            "wrapped wait timeout should be confirmed after forced tree kill"
        )
        assert(
            shutdown_result and shutdown_result.forced == true,
            "wrapped wait timeout should report forced shutdown"
        )
        assert(
            wrapped_timeout_waits == 1,
            "wrapped timeout should wait once after forced tree kill"
        )
        assert(
            wrapped_timeout_callbacks == 1,
            "wrapped timeout should finish lifecycle callbacks once"
        )
        assert(
            #kill_calls == 2,
            "wrapped wait timeout should still send SIGTERM then SIGKILL"
        )
        assert(
            kill_calls[1].pid == -43003 and kill_calls[1].signal == 15,
            "wrapped timeout shutdown should SIGTERM the group first"
        )
        assert(
            kill_calls[2].pid == -43003 and kill_calls[2].signal == 9,
            "wrapped timeout shutdown should SIGKILL the group after timeout"
        )
    end
end, debug.traceback)

vim.system = original_spawn_system
uv.kill = original_spawn_kill

if not ok then
    error(err)
end

original_spawn_system = vim.system
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
