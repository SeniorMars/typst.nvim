local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")
local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
    root_discovery._clear_import_scan_cache()
end

local function write_fixture()
    local project_root = typst_test_cache_path("runtime-resolution-pending")
    vim.fn.delete(project_root, "rf")
    vim.fn.mkdir(project_root .. "/chapters", "p")
    local main = project_root .. "/main.typ"
    local leaf = project_root .. "/chapters/leaf.typ"
    vim.fn.writefile({
        "= Main",
        '#include "chapters/leaf.typ"',
    }, main)
    vim.fn.writefile({ "= Leaf" }, leaf)
    for index = 1, 120 do
        vim.fn.writefile(
            { ("= Extra %03d"):format(index) },
            ("%s/extra-%03d.typ"):format(project_root, index)
        )
    end
    return project_root, leaf
end

cleanup()
local project_root, leaf = write_fixture()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("runtime-resolution-pending-output"),
    project = {
        import_scan = true,
        import_scan_command_wait_ms = 1,
        import_scan_max_depth = 1,
        import_scan_max_files = 200,
    },
    completion = {
        package_cache_prewarm = false,
    },
    preview = {
        open = function()
            error("preview handler should not run while resolution is pending")
        end,
    },
})

vim.cmd.edit(vim.fn.fnameescape(leaf))
vim.bo.filetype = "typst"
typst.project.detach(0)
local attached = assert(typst.project.attach(0))
assert(
    attached.resolution_pending == "import_scan",
    "fixture should start with pending import scan"
)

local compile_callbacks = 0
local compile = typst.compiler.compile({ notify = false }, function(result)
    compile_callbacks = compile_callbacks + 1
    assert(
        result.reason == "resolution_pending",
        "compile callback should receive resolution_pending"
    )
end)
assert(
    compile and compile.reason == "resolution_pending",
    "compile with callback should return resolution_pending payload"
)
assert(compile_callbacks == 1, "compile callback should be called once")

local watch_callbacks = 0
local watch = typst.compiler.watch({ notify = false }, function(result)
    watch_callbacks = watch_callbacks + 1
    assert(
        result.reason == "resolution_pending",
        "watch callback should receive resolution_pending"
    )
end)
assert(
    watch and watch.reason == "resolution_pending",
    "watch with callback should return resolution_pending payload"
)
assert(watch_callbacks == 1, "watch callback should be called once")

local compile_no_callback, compile_no_callback_err =
    typst.compiler.compile({ notify = false })
assert(
    compile_no_callback == nil
        and type(compile_no_callback_err) == "table"
        and compile_no_callback_err.reason == "resolution_pending"
        and compile_no_callback_err.wait_ms == 1,
    "compile without callback should preserve nil,error resolution contract"
)

local watch_no_callback, watch_no_callback_err =
    typst.compiler.watch({ notify = false })
assert(
    watch_no_callback == nil
        and type(watch_no_callback_err) == "table"
        and watch_no_callback_err.reason == "resolution_pending"
        and watch_no_callback_err.wait_ms == 1,
    "watch without callback should preserve nil,error resolution contract"
)

local view, view_err = typst.viewer.view({ notify = false })
assert(
    view == nil
        and type(view_err) == "table"
        and view_err.reason == "resolution_pending",
    "viewer.view without callback should preserve nil,error resolution contract"
)

local preview, preview_err = typst.viewer.preview({ notify = false })
assert(
    preview == nil
        and type(preview_err) == "table"
        and preview_err.reason == "resolution_pending",
    "viewer.preview without callback should preserve nil,error resolution contract"
)

local accepted_callbacks = 0
local accepted = typst.compiler.compile({
    notify = false,
    accept_pending_resolution = true,
}, function(result)
    accepted_callbacks = accepted_callbacks + 1
    assert(
        result.reason ~= "resolution_pending",
        "accept_pending_resolution should bypass pending-resolution block"
    )
end)
assert(
    type(accepted) == "table" and accepted.reason ~= "resolution_pending",
    "accept_pending_resolution should call the compiler handler"
)
assert(
    accepted_callbacks == 0 or accepted_callbacks == 1,
    "accepted pending compile should not duplicate callbacks"
)

cleanup()

vim.cmd("qa!")
