local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset({ force = true })

local opened = 0
local stopped = 0
local open_modes = {}
local finish_stop = nil

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-restart-sequence-output"),
    preview = {
        open = function(_, opts)
            opened = opened + 1
            open_modes[#open_modes + 1] = opts and opts.mode
            return true
        end,
        stop = function()
            stopped = stopped + 1
            local handle = {
                pending = true,
                on_finish_style = "colon",
            }
            function handle:on_finish(callback)
                finish_stop = callback
                return self
            end
            return handle
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "initial preview should open synchronously"
)
local restart = typst.viewer.preview({ restart = true, mode = "slide" })
assert(restart and restart.pending == true, "restart should return handle")
assert(stopped == 1, "restart should stop active preview first")
assert(opened == 1, "restart should not open replacement before stop")
assert(
    typst_test_preview(project).stopping == true,
    "restart should mark preview stopping while stop is pending"
)

assert(type(finish_stop) == "function", "pending stop should be observable")
finish_stop({ ok = true, stopped = true })

assert(opened == 2, "restart should open replacement after stop")
assert(
    open_modes[2] == "slide",
    "restart should preserve replacement open options"
)
assert(restart.pending == false, "restart handle should finish")
assert(
    typst_test_preview(project).active == true,
    "replacement preview should become active"
)
assert(
    typst_test_preview(project).stopping ~= true,
    "replacement preview should clear stopping state"
)

typst.reset({ force = true })
vim.cmd("qa!")
