local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()

---@type any
local callback_project = nil
local callback_mode = nil

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-output"),
    preview = {
        open = function(project, opts)
            callback_project = project
            callback_mode = opts.mode
            return "callback"
        end,
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local preview_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewOpened",
    callback = function(args)
        preview_event = args.data
    end,
})
local result = typst.viewer.preview({ mode = "slide" })
assert(result == "callback", "configured preview callback was not used")
assert(
    callback_project.key == project.key,
    "preview callback received wrong project"
)
assert(callback_mode == "slide", "preview callback received wrong mode")
assert(
    preview_event,
    "TypstPreviewOpened event was not emitted for configured preview callback"
)
assert(
    preview_event.key == project.key,
    "TypstPreviewOpened event had wrong project key"
)
assert(
    preview_event.backend == "callback",
    "TypstPreviewOpened event had wrong backend"
)
assert(preview_event.mode == "slide", "TypstPreviewOpened event had wrong mode")
assert(
    typst_test_preview(project).last_backend == "callback",
    "project should record callback preview backend"
)
assert(
    typst_test_preview(project).last_mode == "slide",
    "project should record callback preview mode"
)
assert(
    typst_test_preview(project).last_command == nil,
    "callback preview should not record a shell command"
)
assert(
    preview_event.preview_backend == "callback",
    "preview event should expose recorded backend"
)
assert(
    preview_event.preview_mode == "slide",
    "preview event should expose recorded mode"
)

vim.cmd("qa!")
