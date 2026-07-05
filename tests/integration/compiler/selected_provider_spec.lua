local ctx = require("tests.helpers.compiler_commands").setup()
local root = ctx.root
local typst = ctx.typst

local fragment_modes = root .. "/tests/fixtures/basic/fragment-modes.typ"
vim.cmd.edit(fragment_modes)
typst.project.set_main(fragment_modes)

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("compiler-commands-output"),
    compile = {
        provider = {
            name = "fragment-start-error",
            compile = function()
                error("fragment provider exploded")
            end,
            start = function()
                return nil
            end,
            stop = function(_project, callback)
                if callback then
                    callback({ code = 0, stale = false, stopped = true })
                end
                return nil
            end,
            status = function(provider_project)
                return typst_test_compiler(provider_project).status
            end,
            output = function(provider_project)
                return typst_test_cache_path("compiler-commands-output/")
                    .. vim.fn.fnamemodify(provider_project.main, ":t:r")
                    .. ".pdf"
            end,
        },
    },
})
local failed_fragment = typst.compiler.compile_selected({
    notify = false,
    line1 = 1,
    line2 = 1,
    range = 1,
})
assert(
    failed_fragment.ok == false,
    "compile_selected should report provider start failures"
)
assert(
    failed_fragment.reason == "compile_start_failed",
    "compile_selected should classify provider start failures"
)
assert(
    failed_fragment.source,
    "compile_selected start failures should report the fragment source path"
)
assert(
    vim.fn.filereadable(failed_fragment.source) == 0,
    "compile_selected should remove fragment source after provider start failures"
)
assert(
    typst_test_compiler(failed_fragment.project).status == "error",
    "failed fragment projects should record an error status"
)
assert(
    typst_test_compiler(failed_fragment.project).process == nil,
    "failed fragment projects should not retain a process handle"
)

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("compiler-commands-output"),
    compile = {
        provider = {
            name = "fragment-nil-start",
            compile = function()
                return nil
            end,
            start = function()
                return nil
            end,
            stop = function(_project, callback)
                if callback then
                    callback({ code = 0, stale = false, stopped = true })
                end
                return nil
            end,
            status = function(provider_project)
                return typst_test_compiler(provider_project).status
            end,
            output = function(provider_project)
                return typst_test_cache_path("compiler-commands-output/")
                    .. vim.fn.fnamemodify(provider_project.main, ":t:r")
                    .. ".pdf"
            end,
        },
    },
})
local declined_fragment = typst.compiler.compile_selected({
    notify = false,
    line1 = 1,
    line2 = 1,
    range = 1,
})
assert(
    declined_fragment.ok == true,
    "compile_selected should keep callback-only providers pending"
)
assert(
    declined_fragment.handle and declined_fragment.handle.pending == true,
    "nil provider handles should receive an adapter-owned pending handle"
)
assert(
    declined_fragment.source,
    "pending callback-only providers should report the fragment source path"
)
assert(
    type(declined_fragment.cancel) == "function",
    "pending fragment compiles should expose cancellation"
)
declined_fragment.cancel({ reason = "test_cancelled" })
assert(
    vim.fn.filereadable(declined_fragment.source) == 0,
    "compile_selected cancellation should remove fragment source"
)
assert(
    typst_test_compiler(declined_fragment.project).status == "idle",
    "cancelled pending fragment projects should return to idle"
)
assert(
    typst_test_compiler(declined_fragment.project).process == nil,
    "nil-handle fragment projects should not retain a process handle"
)
assert(
    typst_test_compiler(declined_fragment.project).last_result.reason
        == "test_cancelled",
    "cancelled pending fragment projects should record the cancellation"
)

vim.cmd("qa!")
