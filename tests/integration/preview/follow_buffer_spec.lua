local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local compiler_service = require("typst.project.services.compiler")
local preview_service = require("typst.project.services.preview")
local session = require("typst.preview.native.session")

typst.reset()

local opened_urls = {}
typst.setup({
    root = root,
    preview = {
        native = "browser",
        follow_buffer = true,
        browser = {
            server = true,
            open = function(url)
                opened_urls[#opened_urls + 1] = url
                return true
            end,
            refresh_ms = 25,
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
local chapter = root .. "/tests/fixtures/basic/chapter.typ"
local first_output = typst_test_cache_path("follow-buffer-first.svg")
local second_output = typst_test_cache_path("follow-buffer-second.svg")
vim.fn.writefile({
    '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"></svg>',
}, first_output)
vim.fn.writefile({
    '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"></svg>',
}, second_output)

vim.cmd.edit(main)
local first_project = typst.project.set_main(main)
compiler_service.set(first_project, {
    output = first_output,
})

local open_result = typst.viewer.preview_open_browser()
assert(
    open_result and open_result.ok == true,
    "native browser preview should open"
)
assert(#opened_urls == 1, "native browser preview should open one URL")
local original_url = opened_urls[1]

vim.cmd.edit(chapter)
local second_project = typst.project.set_main(chapter)
compiler_service.set(second_project, {
    output = second_output,
})

require("typst.preview.follow_buffer").on_buffer(vim.api.nvim_get_current_buf())

assert(
    vim.wait(1000, function()
        local preview = preview_service.get(second_project) or {}
        return preview.active_backend == "native-browser"
            and preview.active_output == second_output
    end, 20),
    "follow_buffer should move native browser ownership to the active buffer project"
)
assert(#opened_urls == 1, "follow_buffer should reuse the existing browser URL")
assert(
    session.browser_url(second_project) == original_url,
    "follow_buffer should keep the browser route URL stable"
)
assert(
    (preview_service.get(first_project) or {}).active ~= true,
    "follow_buffer should clear active ownership from the previous project"
)
assert(
    session.project_state(second_project).output == second_output,
    "follow_buffer route should serve the active buffer project output"
)

typst.viewer.preview_stop({ notify = false })
vim.cmd("qa!")
