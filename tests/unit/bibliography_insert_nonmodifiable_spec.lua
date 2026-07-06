local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset({ force = true })

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
vim.bo[buf].modifiable = false

local result = typst.bibliography.insert({
    key = "doe2026",
    bufnr = buf,
})
assert(result.ok == false, "insert into non-modifiable buffer should fail")
assert(
    result.reason == "buffer_not_modifiable",
    "non-modifiable insert should report a structured reason"
)

vim.bo[buf].modifiable = true
vim.api.nvim_buf_delete(buf, { force = true })

local invalid = typst.bibliography.insert({
    key = "doe2026",
    bufnr = buf,
})
assert(invalid.ok == false, "insert into invalid buffer should fail")
assert(
    invalid.reason == "invalid_buffer",
    "invalid-buffer insert should report a structured reason"
)

vim.cmd("qa!")
