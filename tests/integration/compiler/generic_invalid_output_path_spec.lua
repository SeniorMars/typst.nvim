local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local output_ownership = require("typst.resources.outputs")
local project_store = require("typst.project.store")
local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local function generic_command(marker)
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

local ok, err = xpcall(function()
    cleanup()
    local marker =
        typst_test_cache_path("generic-invalid-output-should-not-run.json")
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("generic-invalid-output"),
        output_name = "bad/name",
        compile = {
            provider = "generic",
            generic = {
                compile = generic_command(marker),
                cwd = "{root}",
            },
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local snapshot = typst.project.set_main(main)
    local project = assert(project_store.get(snapshot.key), "live project")

    local callbacks = 0
    local callback_result = nil
    local result = typst.compiler.compile({}, function(value)
        callbacks = callbacks + 1
        callback_result = value
    end)

    assert(type(result) == "table", "generic compile should return a table")
    assert(result.ok == false, "generic invalid output should fail")
    assert(
        result.reason == "output_path_invalid",
        "generic invalid output should return output_path_invalid"
    )
    assert(
        callback_result == result,
        "generic callback should receive the returned failure"
    )
    assert(callbacks == 1, "generic callback should run once")
    assert(
        typst_test_compiler(project).process == nil,
        "generic invalid output should not store a process"
    )
    assert(
        vim.tbl_count(output_ownership.active_for_project(project)) == 0,
        "generic invalid output should not leave output leases"
    )
    assert(
        vim.fn.filereadable(marker) == 0,
        "generic invalid output should not spawn the configured command"
    )
end, debug.traceback)

cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
