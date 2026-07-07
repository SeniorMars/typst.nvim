local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local output_ownership = require("typst.resources.outputs")
local project_store = require("typst.project.store")
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

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local function attach_project(name)
    local project_root = typst_test_cache_path(name)
    vim.fn.delete(project_root, "rf")
    vim.fn.mkdir(project_root, "p")
    local main = project_root .. "/main.typ"
    vim.fn.writefile({ "= Main" }, main)
    vim.cmd.edit(main)
    local snapshot = typst.project.set_main(main)
    return assert(project_store.get(snapshot.key), "live project"), project_root
end

cleanup()

local inside_marker = typst_test_cache_path("generic-output-policy-inside.json")
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("generic-output-policy-default"),
    compile = {
        provider = "generic",
        generic = {
            compile = command(inside_marker),
            cwd = "{root}",
            output = "explicit/out.pdf",
        },
    },
})
local inside_project, inside_root =
    attach_project("generic-output-policy-inside")
local inside_done = false
local inside_result = typst.compiler.compile({ notify = false }, function(done)
    inside_done = done
end)
assert(
    type(inside_result) == "table" and inside_result.provider == "generic",
    "inside explicit output should start generic compile"
)
assert(
    vim.wait(10000, function()
        return type(inside_done) == "table"
    end, 20),
    "inside explicit output compile should finish"
)
assert(inside_done.code == 0, "inside explicit output should succeed")
assert(
    typst_test_compiler(inside_project).output
        == inside_root .. "/explicit/out.pdf",
    "inside explicit output should be project-relative"
)
assert(
    vim.fn.filereadable(inside_root .. "/explicit/out.pdf") == 1,
    "inside explicit output should be written"
)

cleanup()

local outside_output = vim.fn.tempname() .. "-generic-output/out.pdf"
local outside_marker =
    typst_test_cache_path("generic-output-policy-outside.json")
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("generic-output-policy-default"),
    compile = {
        provider = "generic",
        generic = {
            compile = command(outside_marker),
            cwd = "{root}",
            output = outside_output,
        },
    },
})
local outside_project = attach_project("generic-output-policy-outside")
local callbacks = 0
local invalid = typst.compiler.compile({ notify = false }, function(done)
    callbacks = callbacks + 1
    assert(
        done.reason == "output_path_invalid",
        "callback should receive output policy failure"
    )
end)
assert(invalid.ok == false, "outside explicit output should fail")
assert(
    invalid.reason == "output_path_invalid",
    "outside explicit output should return output_path_invalid"
)
assert(callbacks == 1, "invalid output callback should run once")
assert(
    typst_test_compiler(outside_project).process == nil,
    "outside explicit output should not start a process"
)
assert(
    vim.tbl_count(output_ownership.active_for_project(outside_project)) == 0,
    "outside explicit output should not acquire a lease"
)
assert(
    vim.fn.filereadable(outside_marker) == 0,
    "outside explicit output should not spawn generic command"
)

cleanup()

local allowed_marker =
    typst_test_cache_path("generic-output-policy-allowed.json")
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("generic-output-policy-default"),
    allow_external_output = true,
    compile = {
        provider = "generic",
        generic = {
            compile = command(allowed_marker),
            cwd = "{root}",
            output = outside_output,
        },
    },
})
attach_project("generic-output-policy-allowed")
local allowed_done = false
local allowed = typst.compiler.compile({ notify = false }, function(done)
    allowed_done = done
end)
assert(
    type(allowed) == "table" and allowed.provider == "generic",
    "allowed external explicit output should start"
)
assert(
    vim.wait(10000, function()
        return type(allowed_done) == "table"
    end, 20),
    "allowed external explicit output should finish"
)
assert(
    allowed_done.code == 0,
    "allowed external explicit output should succeed"
)
assert(
    vim.fn.filereadable(outside_output) == 1,
    "allowed external explicit output should be written"
)

cleanup()
vim.fn.delete(vim.fn.fnamemodify(outside_output, ":h"), "rf")
vim.cmd("qa!")
