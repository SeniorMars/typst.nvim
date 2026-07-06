local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset({ force = true })

local empty_old = typst.bibliography.rename_plan({
    old_key = "",
    new_key = "valid-key",
})
assert(empty_old.ok == false, "empty old key should fail")
assert(
    empty_old.reason == "invalid_key",
    "empty old key should report invalid_key"
)

local empty_new = typst.bibliography.rename_plan({
    old_key = "valid-key",
    new_key = "",
})
assert(empty_new.ok == false, "empty new key should fail")
assert(
    empty_new.reason == "invalid_key",
    "empty new key should report invalid_key"
)

local unchanged = typst.bibliography.rename_key({
    old_key = "same-key",
    new_key = "same-key",
})
assert(unchanged.ok == false, "unchanged applied rename should fail")
assert(
    unchanged.reason == "unchanged_key",
    "unchanged applied rename should report unchanged_key"
)

vim.cmd("qa!")
