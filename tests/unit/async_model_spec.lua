local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local provider_adapter = require("typst.integrations.provider_adapter")
local process = require("typst.core.process")

local original_kill = process.kill

local scheduler = {
    queue = {},
}

function scheduler:push(name, fn)
    self.queue[#self.queue + 1] = {
        name = name,
        fn = fn,
    }
end

function scheduler:run()
    while #self.queue > 0 do
        local step = table.remove(self.queue, 1)
        step.fn()
    end
end

local function assert_no_finished_active()
    for _, active in pairs(operation.active()) do
        assert(active.state ~= "finished", "finished operation remained active")
    end
end

local ok, err = xpcall(function()
    local finished = 0
    local cleaned = 0
    local op = operation.new("model-A", {
        cleanup = function()
            cleaned = cleaned + 1
        end,
    })
    op:on_finish(function()
        finished = finished + 1
    end)
    scheduler:push("finish A", function()
        op:finish({ ok = true, code = 0 })
        assert(op.state == "finished", "operation A should finish")
        assert(finished == 1, "operation A callback should run once")
        assert(cleaned == 1, "operation A cleanup should run once")
        assert_no_finished_active()
    end)
    scheduler:push("duplicate A finish", function()
        op:finish({ ok = false, code = 1 })
        assert(finished == 1, "duplicate finish should be ignored")
        assert(cleaned == 1, "duplicate finish should not clean twice")
        assert_no_finished_active()
    end)
    local adapter_results = {}
    scheduler:push("callback before provider return", function()
        local returned = provider_adapter.invoke(
            function(_, _, callback)
                callback({ ok = true, value = "early" })
                callback({ ok = true, value = "duplicate" })
                return { pending = true }
            end,
            nil,
            {},
            {},
            {
                kind = "model-provider",
                provider_name = "early-provider",
                on_result = function(result)
                    adapter_results[#adapter_results + 1] = result
                end,
            }
        )
        assert(returned.ok == true, "early callback result should be returned")
        assert(returned.value == "early", "first callback result should win")
        assert(
            #adapter_results == 1,
            "duplicate provider callback should be ignored"
        )
    end)
    scheduler:push("orphan B then late exit", function()
        local late_finished = 0
        local late_cleaned = 0
        local orphan = operation.new("model-B", {
            cleanup = function()
                late_cleaned = late_cleaned + 1
            end,
        })
        orphan.handle = {}
        orphan:on_finish(function()
            late_finished = late_finished + 1
        end)
        rawset(process, "kill", function()
            return true
        end)
        local cancel_callbacks = 0
        local stopped, cancel_result = orphan:cancel({
            timeout_ms = 0,
            kill_timeout_ms = 0,
        }, function(stopped_result, result)
            cancel_callbacks = cancel_callbacks + 1
            assert(stopped_result == false, "orphan cancel should fail stop")
            assert(
                result.orphaned == true,
                "orphan cancel should retain result"
            )
        end)
        assert(
            not stopped
                and cancel_result
                and cancel_result.pending == true
                and cancel_result.stopping == true,
            "async cancel should not report a confirmed stop"
        )
        assert(
            orphan.state == "orphaned-retained",
            "unconfirmed kill should retain an orphan"
        )
        assert(cancel_callbacks == 1, "orphan cancel callback should settle")
        assert(late_finished == 0, "orphan should not finish early")
        assert(late_cleaned == 0, "orphan should not clean early")
        assert(
            operation.active()[orphan.id] == nil,
            "retained orphan should leave active operations"
        )
        assert(
            operation.retained()[orphan.id] == orphan,
            "orphan should remain reachable as retained"
        )

        orphan:finish({ code = 1, stderr = "late exit" })
        assert(
            late_finished == 1,
            "late orphan exit should run finish callback"
        )
        assert(late_cleaned == 1, "late orphan exit should clean once")
        assert(
            orphan.was_orphaned == true,
            "late orphan exit should retain orphan provenance"
        )
        assert(
            orphan.exited_after_orphan == true,
            "late orphan exit should be marked separately from stop success"
        )
        assert(
            orphan.stopped == false,
            "late orphan exit should not synthesize stopped=true"
        )
        assert_no_finished_active()
        assert(
            operation.retained()[orphan.id] == nil,
            "late orphan exit should clear retained operations"
        )
    end)
    local late_callback
    local timeout_result
    scheduler:push("provider timeout then late callback", function()
        provider_adapter.invoke(
            function(_, _, callback)
                late_callback = callback
                return nil
            end,
            nil,
            {},
            {},
            {
                kind = "model-timeout",
                provider_name = "silent-provider",
                timeout_ms = 5,
                on_result = function(result)
                    timeout_result = result
                end,
            }
        )
        assert(
            vim.wait(1000, function()
                return timeout_result ~= nil
            end, 5),
            "provider timeout should fire"
        )
        assert(
            timeout_result.reason == "timeout",
            "provider should report timeout"
        )
        late_callback({ ok = true, value = "late" })
        assert(
            timeout_result.reason == "timeout",
            "late callback after timeout should not replace terminal result"
        )
    end)
    scheduler:run()
end, debug.traceback)

process.kill = original_kill

if not ok then
    error(err)
end

vim.cmd("qa!")
