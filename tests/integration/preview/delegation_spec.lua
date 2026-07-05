local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local delegated_args = nil
local delegated_buffer = nil
local delegated_cwd = nil
local stopped_buffer = nil
local stopped_cwd = nil
local toggled_buffer = nil
local toggled_cwd = nil
local synced_line = nil
local synced_column = nil
local synced_buffer = nil
local synced_cwd = nil
vim.api.nvim_create_user_command("TypstPreview", function(args)
    delegated_args = args.args
    delegated_buffer = vim.api.nvim_buf_get_name(0)
    delegated_cwd = vim.fn.getcwd()
end, { nargs = "?" })
vim.api.nvim_create_user_command("TypstPreviewStop", function()
    stopped_buffer = vim.api.nvim_buf_get_name(0)
    stopped_cwd = vim.fn.getcwd()
end, {})
vim.api.nvim_create_user_command("TypstPreviewToggle", function()
    toggled_buffer = vim.api.nvim_buf_get_name(0)
    toggled_cwd = vim.fn.getcwd()
end, { nargs = "?" })
vim.api.nvim_create_user_command("TypstPreviewSyncCursor", function()
    synced_line = vim.fn.line(".")
    synced_column = vim.fn.col(".")
    synced_buffer = vim.api.nvim_buf_get_name(0)
    synced_cwd = vim.fn.getcwd()
end, {})
local typst = require("typst")
local project_store = require("typst.project.store")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-delegation-output"),
    preview = {
        provider = "typst-preview.nvim",
    },
})
local command = vim.api.nvim_get_commands({ builtin = false }).TypstPreview
assert(
    command.definition
        ~= require("typst.integrations.typst_preview").own_command_definition,
    "typst.nvim should not clobber an existing TypstPreview command"
)

local main = root .. "/tests/fixtures/basic/main.typ"
local chapter = root .. "/tests/fixtures/basic/chapter.typ"
vim.cmd.edit(chapter)
vim.b.typst_main = main
local project = typst.project.get(0)
local chapter_bufnr = vim.api.nvim_get_current_buf()
local tests_dir = root .. "/tests"
vim.cmd.lcd(vim.fn.fnameescape(tests_dir))

local preview_event = nil
local forward_event = nil
local stopped_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewOpened",
    callback = function(args)
        preview_event = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewForwarded",
    callback = function(args)
        forward_event = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewStopped",
    callback = function(args)
        stopped_event = args.data
    end,
})
typst.viewer.preview({ mode = "document" })
assert(
    delegated_args == "document",
    "existing TypstPreview command did not receive mode"
)
assert(
    delegated_buffer == main,
    "delegated TypstPreview command should run from the resolved main buffer"
)
assert(
    delegated_cwd == root,
    "delegated TypstPreview command should run from the project root"
)
assert(
    vim.api.nvim_get_current_buf() == chapter_bufnr,
    "delegated preview should restore the original buffer"
)
assert(
    vim.fn.getcwd() == tests_dir,
    "delegated preview should restore the caller cwd"
)
assert(
    preview_event,
    "TypstPreviewOpened event was not emitted for delegated preview"
)
assert(
    preview_event.key == project.key,
    "delegated preview event had wrong project key"
)
assert(
    preview_event.backend == "typst-preview.nvim",
    "delegated preview event had wrong backend"
)
assert(
    preview_event.mode == "document",
    "delegated preview event had wrong mode"
)
assert(
    preview_event.command[1] == "TypstPreview document",
    "delegated preview event had wrong command"
)
local live_project = assert(project_store.get(project.key))
assert(
    typst_test_preview(live_project).last_backend == "typst-preview.nvim",
    "project should record delegated preview backend"
)
assert(
    typst_test_preview(live_project).last_mode == "document",
    "project should record delegated preview mode"
)
assert(
    typst_test_preview(live_project).last_command[1] == "TypstPreview document",
    "project should record delegated preview command"
)
assert(
    typst_test_preview(live_project).last_cwd == root,
    "project should record delegated preview cwd"
)
assert(
    preview_event.preview_backend == "typst-preview.nvim",
    "preview event should expose recorded backend"
)
assert(
    preview_event.preview_command[1] == "TypstPreview document",
    "preview event should expose preview command"
)
assert(
    preview_event.preview_cwd == root,
    "preview event should expose preview cwd"
)

assert(
    typst.viewer.preview_stop({ notify = false }) == true,
    "delegated preview stop should run"
)
assert(
    stopped_buffer == main,
    "delegated TypstPreviewStop command should run from the resolved main buffer"
)
assert(
    stopped_cwd == root,
    "delegated TypstPreviewStop command should run from the project root"
)
assert(
    vim.fn.getcwd() == tests_dir,
    "delegated preview stop should restore the caller cwd"
)
assert(
    stopped_event and stopped_event.preview_cwd == root,
    "preview stopped event should expose preview cwd"
)
assert(
    typst_test_preview(live_project).active == false,
    "delegated preview stop should clear active state"
)

assert(
    typst.viewer.preview_toggle({ notify = false }) == true,
    "delegated preview toggle should open when inactive"
)
assert(
    toggled_buffer == main,
    "delegated TypstPreviewToggle command should run from the resolved main buffer"
)
assert(
    toggled_cwd == root,
    "delegated TypstPreviewToggle command should run from the project root"
)
assert(
    vim.fn.getcwd() == tests_dir,
    "delegated preview toggle should restore the caller cwd"
)
assert(
    typst_test_preview(live_project).active == true,
    "delegated preview toggle should mark preview active"
)

local capabilities = typst.viewer.preview_capabilities()
assert(
    capabilities.backend == "typst-preview.nvim",
    "delegated preview capabilities should expose backend"
)
assert(
    capabilities.source_maps == true,
    "typst-preview.nvim should advertise source maps"
)
assert(
    capabilities.inverse == true,
    "typst-preview.nvim should advertise inverse sync"
)
assert(
    capabilities.forward == true,
    "TypstPreviewSyncCursor should advertise forward sync"
)

local done = false
typst.compiler.compile({}, function(result)
    assert(
        result.code == 0,
        "compile failed before delegated preview forward test"
    )
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before delegated preview forward test"
)

vim.cmd.edit(chapter)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local forward = typst.viewer.view_forward({ line = 3, column = 4 })
assert(
    forward == true,
    "view_forward should delegate to TypstPreviewSyncCursor"
)
assert(
    synced_buffer == chapter,
    "TypstPreviewSyncCursor should run from the current source buffer"
)
assert(
    synced_cwd == root,
    "TypstPreviewSyncCursor should run from the project root"
)
assert(
    vim.fn.getcwd() == tests_dir,
    "delegated preview forward should restore the caller cwd"
)
assert(synced_line == 3, "TypstPreviewSyncCursor should receive requested line")
assert(
    synced_column == 4,
    "TypstPreviewSyncCursor should receive requested column"
)
local cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 1 and cursor[2] == 0,
    "delegated preview forward should restore the cursor"
)
assert(
    forward_event,
    "TypstPreviewForwarded event should be emitted for delegated forward sync"
)
assert(
    forward_event.backend == "typst-preview.nvim",
    "delegated forward event should expose backend"
)
assert(
    forward_event.command[1] == "TypstPreviewSyncCursor",
    "delegated forward event should expose command"
)
assert(
    typst_test_preview(live_project).last_backend
        == "typst-preview.nvim-forward-command",
    "project should record forward backend"
)
assert(
    typst_test_preview(live_project).last_command[1] == "TypstPreviewSyncCursor",
    "project should record sync command"
)

vim.api.nvim_buf_set_lines(chapter_bufnr, 0, 1, false, { "αβ Chapter" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
forward = typst.viewer.view_forward({ line = 1, column = 2 })
assert(
    forward == true,
    "delegated preview forward should accept Unicode source lines"
)
assert(
    synced_line == 1,
    "delegated preview forward should move to the Unicode source line"
)
assert(
    synced_column == 1,
    "delegated preview forward should clamp middle-byte columns before syncing"
)
local cursor = vim.api.nvim_win_get_cursor(0)
assert(
    cursor[1] == 1 and cursor[2] == 0,
    "delegated Unicode preview forward should restore the cursor"
)

typst.viewer.preview({ mode = "document" })
local echoed = {}
local old_echo = vim.api.nvim_echo
rawset(vim.api, "nvim_echo", function(chunks)
    for _, chunk in ipairs(chunks) do
        echoed[#echoed + 1] = chunk[1]
    end
end)
typst.ui.info()
vim.api.nvim_echo = old_echo
local text = table.concat(echoed, "\n")
assert(
    text:find("preview backend:%s+typst%-preview%.nvim"),
    "TypstInfo should show preview backend"
)
assert(
    text:find("preview mode:%s+document"),
    "TypstInfo should show preview mode"
)
assert(
    text:find("preview command:%s+TypstPreview document"),
    "TypstInfo should show preview command"
)
assert(
    text:find("preview cwd:%s+" .. vim.pesc(root)),
    "TypstInfo should show preview cwd"
)

assert(
    typst.viewer.preview_stop({ notify = false }) == true,
    "delegated preview should stop before stale-capability test"
)
for _, name in ipairs({
    "TypstPreview",
    "TypstPreviewStop",
    "TypstPreviewToggle",
    "TypstPreviewSyncCursor",
}) do
    pcall(vim.api.nvim_del_user_command, name)
end

capabilities = typst.viewer.preview_capabilities()
assert(
    capabilities.backend ~= "typst-preview.nvim",
    "inactive preview history should not advertise a missing backend"
)
assert(
    capabilities.source_maps == false,
    "missing preview commands should clear source-map capabilities"
)
assert(
    capabilities.inverse == false,
    "missing preview commands should clear inverse capability"
)
assert(
    capabilities.forward == false,
    "missing preview commands should clear forward capability"
)
local stale_inverse = typst.viewer.preview_inverse({
    path = main,
    line = 1,
    column = 1,
    notify = false,
    open = false,
})
assert(
    type(stale_inverse) == "table" and stale_inverse.ok == false,
    "preview inverse should not use stale typst-preview.nvim capabilities"
)

vim.cmd("qa!")
