local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local preview = require("typst.preview.controller")
local typst = require("typst")

typst.reset({ force = true })

local stop_calls = 0

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-stop-for-exit-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            stop_calls = stop_calls + 1
            return {
                pending = true,
                on_finish_style = "colon",
                on_finish = function()
                    return nil
                end,
            }
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
project = require("typst.project.context").live(project) or project

assert(typst.viewer.preview() == true, "preview should open")
local result = preview.stop_for_exit(project, { reason = "exit-test" })

assert(result and result.pending == true, "exit stop should return pending")
assert(stop_calls == 1, "exit stop should call preview stop once")
assert(
    typst_test_preview(project).active == true,
    "pending exit stop should preserve active ownership"
)
assert(
    typst_test_preview(project).stopping == true,
    "pending exit stop should mark stopping"
)
assert(
    typst_test_preview(project).status == "stopping_failed",
    "pending exit stop should be recorded as unconfirmed"
)
assert(
    typst_test_preview(project).stop_prune_reason == "exit-test",
    "pending exit stop should record lifecycle reason"
)

typst.reset({ force = true })
vim.cmd("qa!")
