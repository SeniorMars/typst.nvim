local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("ftplugin-idempotence-output"),
})
local file = typst_test_cache_path("ftplugin-idempotence", "main.nottyp")
vim.fn.delete(vim.fs.dirname(file), "rf")
vim.fn.mkdir(vim.fs.dirname(file), "p")
vim.fn.writefile({ "= Main" }, file)
vim.cmd.edit(file)

local attach_events = 0
local group = vim.api.nvim_create_augroup("TypstFtpluginIdempotenceSpec", {
    clear = true,
})
vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "TypstProjectAttach",
    callback = function()
        attach_events = attach_events + 1
    end,
})
vim.bo.filetype = "typst"
vim.cmd("source " .. vim.fn.fnameescape(root .. "/ftplugin/typst.lua"))
assert(
    vim.wait(1000, function()
        return typst.project.get(0) ~= nil
    end, 10),
    "ftplugin did not attach project"
)
vim.wait(100, function()
    return false
end, 10)

local bufnr = vim.api.nvim_get_current_buf()
local lifecycle_group =
    require("typst.core.lifecycle").buffer_augroup_name(bufnr)
local function autocmd_count(event)
    return #vim.api.nvim_get_autocmds({
        group = lifecycle_group,
        buffer = bufnr,
        event = event,
    })
end

local function map_count()
    local total = 0
    for _, mode in ipairs({ "n", "x", "o", "i" }) do
        total = total + #vim.api.nvim_buf_get_keymap(bufnr, mode)
    end
    return total
end

local project = typst.project.get(0)
assert(project, "buffer should be associated with one project")
assert(project.bufs[bufnr], "project should own buffer")
assert(
    attach_events == 1,
    ("immediate and scheduled attach should emit once, got %d"):format(
        attach_events
    )
)
assert(
    autocmd_count("TextChanged") == 1,
    "TextChanged autocmd should not stack"
)
assert(
    autocmd_count("TextChangedI") == 1,
    "TextChangedI autocmd should not stack"
)
assert(
    autocmd_count("BufWritePost") == 1,
    "BufWritePost autocmd should not stack"
)

local maps_before = map_count()
vim.cmd("source " .. vim.fn.fnameescape(root .. "/ftplugin/typst.lua"))
vim.wait(100, function()
    return false
end, 10)

assert(attach_events == 1, "re-sourcing ftplugin should not emit attach")
assert(autocmd_count("TextChanged") == 1, "re-source should not stack autocmds")
assert(map_count() == maps_before, "re-source should not stack buffer mappings")

vim.cmd("qa!")
