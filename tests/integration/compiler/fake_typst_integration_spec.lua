local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local project_services = require("typst.project.services")
local util = require("typst.core.util")
local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(vim.cmd, "silent! %bwipeout!")
end

local function has_dependency(project, path)
    return project_services.graph(project).dependencies[util.normalize(path)]
        == true
end

cleanup()

local project_root = root .. "/tests/fixtures/typst/project"
local main = project_root .. "/main.typ"
local chapter = project_root .. "/chapter.typ"
local image = project_root .. "/assets/image.svg"
local refs = project_root .. "/bib/references.bib"
local refreshes = {}

local ok, err = xpcall(function()
    typst.setup({
        root = project_root,
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-integration.py"
        ),
        output_dir = typst_test_cache_path("fake-typst-integration-output"),
        compile = {
            deps = true,
            watch_output = "human",
        },
        preview = {
            refresh = function(project, result, opts)
                refreshes[#refreshes + 1] = {
                    key = project.key,
                    code = result.code,
                    source = opts and opts.source,
                    watch = opts and opts.watch,
                    cycle = opts and opts.cycle,
                }
                return true
            end,
        },
    })

    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    vim.fn.delete(typst_test_compiler(project).output)

    local compile_result = nil
    typst.compiler.compile({}, function(result)
        compile_result = result
    end)

    assert(
        vim.wait(10000, function()
            return compile_result ~= nil
        end, 20),
        "fake Typst compile did not finish"
    )
    assert(compile_result.code == 0, "fake Typst compile failed")
    assert(
        vim.fn.filereadable(typst_test_compiler(project).output) == 1,
        "fake Typst compile did not write output"
    )
    assert(
        compile_result.deps_path
            and vim.fn.filereadable(compile_result.deps_path) == 0,
        "compile dependency temp file should be consumed and removed"
    )
    assert(has_dependency(project, main), "compile deps should include main")
    assert(
        has_dependency(project, chapter),
        "compile deps should include imported chapter"
    )
    assert(has_dependency(project, image), "compile deps should include image")
    assert(
        has_dependency(project, refs),
        "compile deps should include bibliography"
    )
    assert(
        refreshes[1]
            and refreshes[1].source == "compile"
            and refreshes[1].watch == false,
        "compile should refresh preview consumers"
    )

    refreshes = {}
    local watch_results = {}
    vim.fn.delete(typst_test_compiler(project).output)
    vim.env.TYPST_NVIM_FAKE_TYPST_DELAY_OUTPUT_MS = "250"
    typst.compiler.watch({}, function(result)
        watch_results[#watch_results + 1] = result
    end)

    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher
                and typst_test_compiler(project).watcher.last_cycle_status == "success"
                and #watch_results >= 1
                and #refreshes >= 1
        end, 20),
        "fake Typst watch did not report a successful cycle"
    )
    assert(
        watch_results[1].watch == true and watch_results[1].code == 0,
        "fake Typst watch should report a successful watch payload"
    )
    assert(
        (watch_results[1].output_wait_attempts or 0) > 0,
        "fake Typst watch should wait for delayed output"
    )
    assert(
        refreshes[1].source == "watch" and refreshes[1].watch == true,
        "watch cycle should refresh preview consumers"
    )
    assert(
        has_dependency(project, chapter),
        "watch deps should include chapter"
    )
    assert(has_dependency(project, image), "watch deps should include image")
    assert(has_dependency(project, refs), "watch deps should include refs")

    local stopped = false
    typst.compiler.stop({}, function(result)
        stopped = result.stopped == true
    end)
    assert(
        vim.wait(10000, function()
            return stopped
                and typst_test_compiler(project).watcher == nil
                and typst_test_compiler(project).status == "idle"
        end, 20),
        "fake Typst watcher did not stop"
    )
end, debug.traceback)

vim.env.TYPST_NVIM_FAKE_TYPST_DELAY_OUTPUT_MS = nil
cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
