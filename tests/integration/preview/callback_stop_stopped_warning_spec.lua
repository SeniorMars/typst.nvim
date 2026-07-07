local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local main = root .. "/tests/fixtures/basic/main.typ"

local function edit_main()
    vim.cmd.edit(main)
    return typst.project.set_main(main)
end

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path(
        "preview-callback-stop-stopped-warning-output"
    ),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            return {
                ok = false,
                stopped = true,
                warning = true,
                reason = "callback_warning",
                message = "callback reported a warning after stop",
            }
        end,
    },
})

local project = edit_main()
assert(
    typst.viewer.preview({ notify = false }) == true,
    "callback stop-warning fixture should open a preview first"
)

local stopped_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewStopped",
    once = true,
    callback = function(args)
        stopped_event = args.data
    end,
})

local result = typst.viewer.preview_stop({ notify = false })
assert(
    result and result.ok == false and result.stopped == true,
    "callback stop warning should preserve the backend result shape"
)
assert(
    result.warning == true and result.reason == "callback_warning",
    "callback stop warning should preserve warning metadata"
)

local preview = typst_test_preview(project)
assert(
    preview.active == false,
    "stopped callback warning should clear active preview state"
)
assert(
    preview.last_result and preview.last_result.reason == "callback_warning",
    "stopped callback warning should be recorded as the last result"
)
assert(
    stopped_event and stopped_event.backend == "callback",
    "stopped callback warning should emit TypstPreviewStopped"
)

typst.reset({ force = true })
vim.cmd("qa!")
