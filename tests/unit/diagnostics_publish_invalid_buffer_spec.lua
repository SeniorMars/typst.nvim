local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local project_services = require("typst.project.services")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    diagnostics = {
        enabled = true,
        use_quickfix = true,
    },
})
local project = {
    key = "diagnostics-invalid-buffer",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    services = project_services.new_state(),
}

local valid_bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(valid_bufnr, "typst-diagnostics-valid.typ")

local invalid_bufnr = 999999
assert(
    not vim.api.nvim_buf_is_valid(invalid_bufnr),
    "test invalid buffer must not exist"
)

local by_buffer = {
    [invalid_bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "invalid buffer diagnostic",
            severity = vim.diagnostic.severity.ERROR,
        },
    },
    [valid_bufnr] = {
        {
            lnum = 0,
            col = 0,
            message = "valid buffer diagnostic",
            severity = vim.diagnostic.severity.ERROR,
        },
    },
}

local published, items = diagnostics.publish_by_buffer(project, by_buffer)
assert(
    published[invalid_bufnr] == nil,
    "invalid diagnostic buffer should be skipped"
)
assert(
    published[valid_bufnr] and #published[valid_bufnr] == 1,
    "valid diagnostic buffer should publish"
)
assert(#items == 1, "quickfix should include only valid buffers")
assert(
    items[1].bufnr == valid_bufnr,
    "quickfix item should target valid buffer"
)

local quickfix_items = diagnostics.quickfix_items(by_buffer)
assert(#quickfix_items == 1, "quickfix conversion should skip invalid buffers")
assert(
    quickfix_items[1].bufnr == valid_bufnr,
    "quickfix conversion should keep the valid buffer"
)

vim.api.nvim_buf_delete(valid_bufnr, { force = true })
vim.cmd("qa!")
