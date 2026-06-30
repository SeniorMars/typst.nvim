local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local schema = require("typst.config.schema")

local ok, err = pcall(schema.string_list, { pdf = true }, "attachments")
assert(not ok, "string_list should reject keyed maps")
assert(
    tostring(err):find("invalid key", 1, true),
    "keyed map error should identify invalid key"
)

ok, err = pcall(schema.string_list, { "pdf", nil, "file" }, "attachments")
assert(not ok, "string_list should reject sparse arrays")
assert(
    tostring(err):find("missing index 2", 1, true),
    "sparse array error should identify the hole"
)

local list = schema.string_list({ "pdf", "file" }, "attachments")
assert(#list == 2 and list[2] == "file", "string_list should accept arrays")

vim.cmd("qa!")
