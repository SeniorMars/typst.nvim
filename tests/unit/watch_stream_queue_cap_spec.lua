local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local watch_state = require("typst.compiler.watch.state")
local compiler_service = require("typst.project.services.compiler")
local log = require("typst.core.log")
local project_services = require("typst.project.services")

local original_schedule = vim.schedule
local scheduled = nil
vim.schedule = function(callback)
    scheduled = callback
end

local ok, err = xpcall(function()
    local project = {
        key = "watch-stream-queue-cap",
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
        bufs = {},
        services = project_services.new_state(),
    }
    local watcher = {
        generation = 1,
        stdout = "",
        stderr = "",
        line_buffers = {},
    }
    compiler_service.set(project, {
        watcher = watcher,
        watch_generation = watcher.generation,
    })

    local function enqueue_flood()
        local total = 0
        for _ = 1, 400 do
            local chunk = ("x"):rep(1024)
            total = total + #chunk
            watch_state.enqueue_stream(project, watcher, "stdout", chunk)
        end
        return total
    end

    local function truncation_warning_count()
        local count = 0
        for _, entry in ipairs(log.entries()) do
            if entry.message == "watch stream queue truncated" then
                count = count + 1
            end
        end
        return count
    end

    log.clear()
    local total = enqueue_flood()

    assert(scheduled, "stream queue should schedule a drain")
    assert(
        (watcher.stream_queue_bytes or 0) <= 256 * 1024,
        "pre-drain stream queue should stay within byte cap"
    )
    assert(
        (watcher.stream_queue_chunks or 0) <= 1024,
        "pre-drain stream queue should stay within chunk cap"
    )
    assert(
        watcher.stream_queue_truncated == true,
        "overflow should mark the queue truncated"
    )
    assert(
        (watcher.stream_queue_dropped_bytes or 0) > 0
            and (watcher.stream_queue_dropped_bytes or 0) < total,
        "overflow should record dropped bytes"
    )

    scheduled()
    assert(
        watcher.stream_queue_bytes == 0 and watcher.stream_queue_chunks == 0,
        "draining should reset pre-drain queue counters"
    )
    assert(
        watcher.stderr:find("truncated before processing", 1, true) ~= nil,
        "draining should retain a truncation warning"
    )
    assert(
        truncation_warning_count() == 1,
        "first truncated drain should log one warning"
    )

    scheduled = nil
    enqueue_flood()
    assert(scheduled, "second flood should schedule another drain")
    scheduled()
    assert(
        truncation_warning_count() == 1,
        "sustained stream truncation should throttle repeated warnings"
    )
end, debug.traceback)

vim.schedule = original_schedule

if not ok then
    error(err)
end

vim.cmd("qa!")
