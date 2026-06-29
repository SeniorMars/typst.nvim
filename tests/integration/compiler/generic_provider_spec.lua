local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")

local function command(marker)
    local cmd = helpers.python_command(
        root .. "/tests/fixtures/fake-generic-compiler.py"
    )
    vim.list_extend(cmd, {
        "compile",
        "{main}",
        "{output}",
        "{root}",
        "{profile}",
        "{source}",
        "{stdin}",
        marker,
    })
    return cmd
end

local function task_command(marker)
    local cmd = helpers.python_command(
        root .. "/tests/fixtures/fake-generic-compiler.py"
    )
    vim.list_extend(cmd, {
        "compile",
        "{main}",
        "{output}",
        "{root}",
        "{profile}",
        "{provider}",
        "{source}",
        "{stdin}",
        marker,
    })
    return cmd
end

local function watch_command(marker)
    local cmd = helpers.python_command(
        root .. "/tests/fixtures/fake-generic-compiler.py"
    )
    vim.list_extend(
        cmd,
        { "watch", "{main}", "{output}", "{root}", "{profile}", marker }
    )
    return cmd
end

typst.reset()
local compile_marker = typst_test_cache_path("generic-provider-compile.json")
local watch_marker = typst_test_cache_path("generic-provider-watch.json")
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("generic-provider-default"),
    compile = {
        provider = "generic",
        generic = {
            compile = command(compile_marker),
            watch = watch_command(watch_marker),
            cwd = "{root}",
        },
        fragments = {
            output_dir = typst_test_cache_path("generic-provider-fragments"),
        },
        profiles = {
            generic = {
                output_dir = typst_test_cache_path("generic-provider-profile"),
                output_name = "custom",
            },
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local main_bufnr = vim.api.nvim_get_current_buf()
local project = typst.project.set_main(main)

local compile_done = false
local compile_code = nil
local handle = typst.compiler.compile({ profile = "generic" }, function(result)
    compile_code = result.code
    compile_done = true
end)

assert(
    handle.provider == "generic",
    "generic compile should return provider state"
)
assert(
    typst_test_compiler(project).process == handle,
    "generic compile should be tracked as the active process"
)
assert(
    vim.wait(10000, function()
        return compile_done
    end, 20),
    "generic provider compile did not finish"
)
assert(
    compile_code == 0,
    ("generic provider compile failed: %s"):format(vim.inspect(compile_code))
)
assert(
    typst_test_compiler(project).process == nil,
    "generic provider compile should clear the active process"
)
assert(
    typst_test_compiler(project).status == "success",
    "generic provider compile should set success status"
)
assert(
    typst_test_compiler(project).output:match(
        "generic%-provider%-profile/custom%.pdf$"
    ),
    typst_test_compiler(project).output
)
assert(
    vim.fn.filereadable(typst_test_compiler(project).output) == 1,
    "generic provider should write configured output"
)
local generic_output = typst_test_compiler(project).output
assert(vim.fn.writefile({
    "user-modified generic compile output",
}, generic_output) == 0, "failed to modify generic compile output")
local generic_clean = typst.viewer.clean({ all = true })
assert(
    generic_clean.skipped_output and generic_clean.reason == "changed_output",
    "generic compile outputs should be protected by ownership fingerprints"
)
assert(
    vim.fn.filereadable(generic_output) == 1,
    "generic compile output should survive unforced clean after modification"
)
assert(
    typst.viewer.clean({ all = true, force = true }).output_deleted,
    "forced clean should remove changed generic compile output"
)

local marker =
    vim.json.decode(table.concat(vim.fn.readfile(compile_marker), "\n"))
assert(marker.cwd == root, "generic provider should run in configured cwd")
assert(marker.argv[2] == main, "generic provider should replace {main}")
assert(
    marker.argv[3] == typst_test_compiler(project).output,
    "generic provider should replace {output}"
)
assert(marker.argv[4] == root, "generic provider should replace {root}")
assert(marker.argv[5] == "generic", "generic provider should replace {profile}")
assert(marker.argv[6] == main, "generic provider should replace {source}")
assert(marker.argv[7] == "", "generic provider should replace {stdin}")
assert(
    not table
        .concat(typst_test_compiler(project).last_command, " ")
        :find("{main}", 1, true),
    "generic command should not keep placeholders"
)

vim.api.nvim_set_current_buf(main_bufnr)
local selected_done = false
local selected_code = nil
local selected = typst.compiler.compile_selected({
    notify = false,
    profile = "generic",
    line1 = 1,
    line2 = 1,
    range = 1,
}, function(result)
    selected_code = result.code
    selected_done = true
end)
assert(selected.ok == true, "generic selected-fragment compile should start")
assert(
    selected.source_mode == "stdin",
    "generic selected-fragment compile should use stdin by default"
)
assert(
    vim.wait(10000, function()
        return selected_done
    end, 20),
    "generic selected-fragment compile did not finish"
)
assert(
    selected_code == 0,
    ("generic selected-fragment compile failed: %s"):format(
        vim.inspect(selected_code)
    )
)
assert(
    vim.fn.filereadable(selected.output) == 1,
    "generic selected-fragment compile should write output"
)
local selected_marker =
    vim.json.decode(table.concat(vim.fn.readfile(compile_marker), "\n"))
assert(
    selected_marker.argv[2] == "-",
    "generic selected-fragment compile should replace {main} with stdin"
)
assert(
    selected_marker.stdin:find("= Main", 1, true),
    "generic selected-fragment compile should pass generated source on stdin"
)
assert(
    selected_marker.argv[3] == selected.output,
    "generic selected-fragment compile should replace {output}"
)
assert(
    selected_marker.argv[6] == main,
    "generic selected-fragment compile should expose original source"
)
assert(
    selected_marker.argv[7] == "1",
    "generic selected-fragment compile should expose stdin placeholder"
)

local watcher = typst.compiler.watch({ profile = "generic" })
assert(
    watcher.provider == "generic",
    "generic watch should return provider state"
)
assert(
    typst_test_compiler(project).watcher == watcher,
    "generic watch should be tracked as active watcher"
)
assert(
    typst_test_compiler(project).status == "watching",
    "generic watch should set watching status"
)
assert(
    vim.wait(10000, function()
        return vim.fn.filereadable(watch_marker) == 1
    end, 20),
    "generic watch command should start"
)
typst.compiler.stop()
assert(
    typst_test_compiler(project).watcher == nil,
    "generic stop should clear active watcher"
)
assert(
    typst_test_compiler(project).status == "idle",
    "generic stop should set idle status"
)

typst.reset()
local task_marker = typst_test_cache_path("task-provider-compile.json")
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("task-provider-output"),
    compile = {
        provider = "task",
        task = {
            compile = task_command(task_marker),
        },
        fragments = {
            output_dir = typst_test_cache_path("task-provider-fragments"),
        },
    },
})

vim.cmd.edit(main)
local task_bufnr = vim.api.nvim_get_current_buf()
local task_project = typst.project.set_main(main)
local task_done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "task provider compile failed")
    task_done = true
end)
assert(
    vim.wait(10000, function()
        return task_done
    end, 20),
    "task provider compile did not finish"
)
assert(
    vim.fn.filereadable(typst_test_compiler(task_project).output) == 1,
    "task provider should write output"
)
assert(
    vim.json.decode(table.concat(vim.fn.readfile(task_marker), "\n")).argv[1]
        == "compile",
    "task provider ran wrong mode"
)
local task_marker_data =
    vim.json.decode(table.concat(vim.fn.readfile(task_marker), "\n"))
assert(
    task_marker_data.provider == "task",
    "task provider should replace {provider}"
)
assert(
    task_marker_data.argv[6] == "task",
    "task provider command should receive provider placeholder"
)
assert(
    task_marker_data.argv[7] == main,
    "task provider command should receive source placeholder"
)
assert(
    task_marker_data.argv[8] == "",
    "task provider command should receive stdin placeholder"
)
assert(
    not table
        .concat(typst_test_compiler(task_project).last_command, " ")
        :find("{provider}", 1, true),
    "task command should not keep provider placeholder"
)

vim.api.nvim_set_current_buf(task_bufnr)
local task_selected_done = false
local task_selected_code = nil
local task_selected = typst.compiler.compile_selected({
    notify = false,
    line1 = 1,
    line2 = 1,
    range = 1,
}, function(result)
    task_selected_code = result.code
    task_selected_done = true
end)
assert(task_selected.ok == true, "task selected-fragment compile should start")
assert(
    task_selected.source_mode == "stdin",
    "task selected-fragment compile should use stdin by default"
)
assert(
    vim.wait(10000, function()
        return task_selected_done
    end, 20),
    "task selected-fragment compile did not finish"
)
assert(
    task_selected_code == 0,
    ("task selected-fragment compile failed: %s"):format(
        vim.inspect(task_selected_code)
    )
)
local task_selected_marker =
    vim.json.decode(table.concat(vim.fn.readfile(task_marker), "\n"))
assert(
    task_selected_marker.argv[2] == "-",
    "task selected-fragment compile should replace {main} with stdin"
)
assert(
    task_selected_marker.stdin:find("= Main", 1, true),
    "task selected-fragment compile should pass generated source on stdin"
)
assert(
    task_selected_marker.argv[6] == "task",
    "task selected-fragment compile should preserve provider placeholder"
)
assert(
    task_selected_marker.argv[7] == main,
    "task selected-fragment compile should expose original source"
)
assert(
    task_selected_marker.argv[8] == "1",
    "task selected-fragment compile should expose stdin placeholder"
)

typst.reset()
local process = require("typst.core.process")
local original_system = process.system
local original_spawn = process.spawn
local original_shutdown = process.shutdown
local restart_events = {}
local restart_handles = {}

local ok, err = xpcall(function()
    local function fake_spawn(command)
        local id = #restart_handles + 1
        restart_events[#restart_events + 1] = ("spawn:%d:%s"):format(
            id,
            command[#command]
        )
        local handle = {
            id = id,
            pid = 5200 + id,
        }

        function handle:is_closing()
            return false
        end

        restart_handles[id] = handle
        return handle
    end

    process.spawn = function(command)
        return fake_spawn(command)
    end

    process.system = function(command)
        return fake_spawn(command)
    end

    process.shutdown = function(handle)
        restart_events[#restart_events + 1] = ("shutdown:%d"):format(handle.id)
        return true, { stopped = true }
    end

    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("generic-provider-restart"),
        compile = {
            provider = "generic",
            generic = {
                compile = { "fake-generic", "{main}", "{output}", "{profile}" },
                cwd = "{root}",
            },
            profiles = {
                replacement = {},
            },
        },
    })

    vim.cmd.edit(main)
    local restart_project = typst.project.set_main(main)
    local first = typst.compiler.compile()
    assert(
        first and typst_test_compiler(restart_project).process == first,
        "first generic compile should be active"
    )

    local second = typst.compiler.compile({ profile = "replacement" })
    assert(
        second
            and second.restart == true
            and second.next_handle
                == typst_test_compiler(restart_project).process,
        "replacement generic compile should be active through the restart handle"
    )
    assert(
        vim.deep_equal(restart_events, {
            "spawn:1:",
            "shutdown:1",
            "spawn:2:replacement",
        }),
        "generic replacement should wait for shutdown before spawning the replacement"
    )

    typst_test_compiler(restart_project).process = nil
    typst_test_compiler(restart_project).watcher = nil
    restart_project.compiler_provider = nil

    typst.reset()
    restart_events = {}
    restart_handles = {}
    process.spawn = function(command)
        return fake_spawn(command)
    end
    process.system = function(command)
        return fake_spawn(command)
    end
    process.shutdown = function(handle)
        restart_events[#restart_events + 1] = ("shutdown:%d"):format(handle.id)
        return false,
            {
                stopped = false,
                error = "simulated shutdown failure",
            }
    end

    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("generic-provider-restart-failure"),
        compile = {
            provider = "generic",
            generic = {
                compile = { "fake-generic", "{main}", "{output}", "{profile}" },
                cwd = "{root}",
            },
            profiles = {
                replacement = {},
            },
        },
    })

    vim.cmd.edit(main)
    local retained_project = typst.project.set_main(main)
    local retained = typst.compiler.compile()
    local replacement_result
    local replacement = typst.compiler.compile(
        { profile = "replacement" },
        function(result)
            replacement_result = result
        end
    )
    assert(
        replacement
            and replacement.restart == true
            and replacement.stop_handle == retained
            and replacement.result == replacement_result,
        "failed generic shutdown should return a restart handle for the retained process"
    )
    assert(
        typst_test_compiler(retained_project).process == retained,
        "failed generic shutdown should retain ownership of the old process"
    )
    assert(
        vim.deep_equal(restart_events, {
            "spawn:1:",
            "shutdown:1",
        }),
        "generic replacement should not spawn after unconfirmed shutdown"
    )
    assert(
        replacement_result and replacement_result.stopped == false,
        "failed generic shutdown should report an unstopped result"
    )

    typst_test_compiler(retained_project).process = nil
    typst_test_compiler(retained_project).watcher = nil
    retained_project.compiler_provider = nil
end, debug.traceback)

process.system = original_system
process.spawn = original_spawn
process.shutdown = original_shutdown

if not ok then
    error(err)
end

vim.cmd("qa!")
