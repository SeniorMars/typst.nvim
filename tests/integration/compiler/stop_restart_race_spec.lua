local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    print("stop_restart_race_spec: skipped on Windows")
    vim.cmd("qa!")
    return
end

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")

local function cleanup(group)
    pcall(function()
        typst.reset({ force = true })
    end)
    if group then
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local group =
    vim.api.nvim_create_augroup("TypstStopRestartRaceSpec", { clear = true })
cleanup(group)
group =
    vim.api.nvim_create_augroup("TypstStopRestartRaceSpec", { clear = true })
local marker = typst_test_cache_path("stop-restart-race/events.txt")
vim.fn.delete(marker)
vim.fn.mkdir(vim.fs.dirname(marker), "p")

local old_marker = vim.env.TYPST_NVIM_RACE_MARKER
vim.env.TYPST_NVIM_RACE_MARKER = marker

local ok, err = xpcall(function()
    typst.setup({
        root = root,
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-race.py"
        ),
        output_dir = typst_test_cache_path("stop-restart-race-output"),
        compile = {
            deps = false,
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)

    local initial_watch_cycles = 0
    ---@type any
    local first_watch = typst.compiler.watch({}, function(result)
        if result.watch and result.code == 0 then
            initial_watch_cycles = initial_watch_cycles + 1
        end
    end)
    assert(first_watch, "initial watch should start")
    assert(
        vim.wait(10000, function()
            local watcher = typst_test_compiler(project).watcher
            return watcher ~= nil
                and watcher.handle == first_watch
                and initial_watch_cycles >= 1
        end, 20),
        "initial watcher did not report a successful cycle"
    )

    ---@type any
    local compile_started_handle = nil
    ---@type any
    local watch_restart = nil
    local compile_callback_called = false
    local final_watch_cycles = 0
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStarted",
        callback = function()
            if compile_started_handle then
                return
            end
            compile_started_handle = typst_test_compiler(project).process
            watch_restart = typst.compiler.watch({}, function(result)
                if result.watch and result.code == 0 then
                    final_watch_cycles = final_watch_cycles + 1
                end
            end)
        end,
    })
    local compile_restart = typst.compiler.compile({}, function()
        compile_callback_called = true
    end)
    assert(
        compile_restart and compile_restart.restart == true,
        "compile while watching should return a restart handle"
    )
    assert(
        compile_restart.stop_handle == first_watch,
        "compile restart should stop the initial watcher first"
    )

    assert(
        vim.wait(10000, function()
            return compile_started_handle ~= nil and watch_restart ~= nil
        end, 20),
        "compile-start handler did not request replacement watch"
    )
    assert(
        watch_restart.restart == true or watch_restart.deferred == true,
        "watch requested from compile-start should be deferred or restarted"
    )

    assert(
        vim.wait(10000, function()
            local compiler = typst_test_compiler(project)
            return first_watch:is_closing()
                and compile_started_handle:is_closing()
                and compiler.process == nil
                and compiler.watcher ~= nil
                and compiler.watcher.handle ~= first_watch
                and final_watch_cycles >= 1
        end, 20),
        "overlapping compile/watch restart did not settle on a final watcher"
    )
    assert(
        typst_test_compiler(project).status == "watching",
        "final compiler state should be watching"
    )

    vim.wait(200, function()
        return compile_callback_called
    end, 20)
    assert(
        not compile_callback_called,
        "stopped intermediate compile should not call the public callback"
    )

    assert(
        vim.wait(1000, function()
            local watch_starts = 0
            local text = table.concat(vim.fn.readfile(marker), "\n")
            for _ in text:gmatch("watch%-start") do
                watch_starts = watch_starts + 1
            end
            return watch_starts >= 2 and text:find("watch-exit", 1, true) ~= nil
        end, 20),
        "race fixture should record initial watcher stop and replacement watcher"
    )

    local stopped = false
    typst.compiler.stop({}, function(result)
        stopped = result.stopped == true
    end)
    assert(
        vim.wait(10000, function()
            return stopped and typst_test_compiler(project).watcher == nil
        end, 20),
        "final watcher did not stop cleanly"
    )
end, debug.traceback)

vim.env.TYPST_NVIM_RACE_MARKER = old_marker
cleanup(group)

if not ok then
    error(err)
end

vim.cmd("qa!")
