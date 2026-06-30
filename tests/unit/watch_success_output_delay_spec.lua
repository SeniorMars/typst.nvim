local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local compiler_watch = require("typst.compiler.watch.state")
local compiler_dependencies = require("typst.compiler.dependencies")
local compiler_service = require("typst.project.services.compiler")
local project_services = require("typst.project.services")

local output = typst_test_cache_path("watch-output-delay", "main.pdf")
vim.fn.delete(vim.fs.dirname(output), "rf")
vim.fn.mkdir(vim.fs.dirname(output), "p")

local project = {
    key = "watch-output-delay",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    bufs = {},
    services = project_services.new_state(),
}
compiler_service.set(project, {
    output = output,
    status = "watching",
})

local original_refresh_watcher = compiler_dependencies.refresh_watcher
compiler_dependencies.refresh_watcher = function() end

local timer = assert((vim.uv or vim.loop).new_timer())
local callback_result = nil
local seen_success
local seen_failure = false
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompileSuccess",
    once = true,
    callback = function(args)
        seen_success = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompileFailed",
    callback = function()
        seen_failure = true
    end,
})
local watcher = {
    generation = 1,
    watch_output_wait_ms = 1000,
    callback = function(result)
        callback_result = result
    end,
    current_cycle = {
        id = 1,
        generation = 1,
        stdout = "",
        stderr = "",
        started_at = (vim.uv or vim.loop).hrtime(),
        finished = false,
    },
}
compiler_service.set(project, { watcher = watcher, watch_generation = 1 })

local ok, err = xpcall(function()
    timer:start(
        120,
        0,
        vim.schedule_wrap(function()
            timer:stop()
            timer:close()
            vim.fn.writefile({ "%PDF-1.7" }, output)
        end)
    )

    compiler_watch.finish_cycle(project, watcher, 0, "compiled successfully")
    local first_finish_timer = watcher.current_cycle.finish_timer
    assert(first_finish_timer, "missing output should schedule output wait")
    compiler_watch.finish_cycle(project, watcher, 0, "duplicate success")
    assert(
        watcher.current_cycle.finish_timer == first_finish_timer,
        "duplicate success should not replace the output wait timer"
    )

    assert(
        vim.wait(1500, function()
            return callback_result ~= nil
        end, 10),
        "watch cycle did not wait for delayed output"
    )
    assert(callback_result.code == 0, "delayed output should stay successful")
    assert(
        (callback_result.output_wait_attempts or 0) > 0,
        "watch result should record output wait attempts"
    )
    assert(seen_success, "watch success event should be emitted")
    assert(
        seen_failure == false,
        "delayed output should not emit a failure event"
    )
    assert(seen_success.code == 0, "watch success event should retain code")
    assert(
        seen_success.status == "success",
        "watch success event should report success status"
    )
    assert(
        seen_success.generation == watcher.generation,
        "watch success event should retain watcher generation"
    )
    assert(
        seen_success.watch_generation == watcher.generation,
        "watch success event should retain watch generation"
    )
    assert(
        seen_success.cycle_generation == watcher.current_cycle.generation,
        "watch success event should retain cycle generation"
    )
    assert(
        (seen_success.output_wait_attempts or 0) > 0,
        "watch success event should retain output wait attempts"
    )
end, debug.traceback)

compiler_dependencies.refresh_watcher = original_refresh_watcher
if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
end

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit")
end

vim.cmd("qa!")
