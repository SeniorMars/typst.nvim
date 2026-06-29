local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local docs = require("typst.config.docs")
local util = require("typst.core.util")

local function write(path, text)
    local ok, err = util.atomic_writefile(vim.split(text, "\n"), path)
    assert(ok, "failed to write " .. path .. ": " .. vim.inspect(err))
end

write(root .. "/docs/config-reference.md", docs.markdown())
write(root .. "/data/config-schema.json", docs.schema_json())

print("generated config docs and schema")
vim.cmd("qa!")
