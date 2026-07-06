local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local function autocmd_count(group)
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = group })
    if not ok then
        return 0
    end
    return #autocmds
end

typst.reset({ force = true })
typst.setup({
    preview = {
        follow_buffer = false,
    },
})
vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "typst"

local schedule_calls = 0
local original_schedule = vim.schedule
rawset(vim, "schedule", function(_)
    schedule_calls = schedule_calls + 1
end)
local ok, err = xpcall(function()
    assert(
        autocmd_count("typst_nvim_preview_follow_buffer") == 0,
        "disabled follow_buffer should not install global autocmds"
    )
    assert(
        schedule_calls == 0,
        "disabled follow_buffer should not schedule BufEnter work"
    )

    typst.setup({
        preview = {
            follow_buffer = true,
        },
    })
    assert(
        autocmd_count("typst_nvim_preview_follow_buffer") > 0,
        "enabled follow_buffer should install global autocmds"
    )
    vim.api.nvim_exec_autocmds("BufEnter", {
        group = "typst_nvim_preview_follow_buffer",
        buffer = bufnr,
        modeline = false,
    })
    assert(
        schedule_calls == 1,
        "enabled follow_buffer should schedule BufEnter work"
    )

    typst.setup({
        preview = {
            follow_buffer = false,
        },
    })
    assert(
        autocmd_count("typst_nvim_preview_follow_buffer") == 0,
        "disabling follow_buffer should remove global autocmds"
    )
end, debug.traceback)

vim.schedule = original_schedule
typst.reset({ force = true })
if not ok then
    error(err)
end

local store = require("typst.project.store")
local project = store.create(root, root .. "/tests/fixtures/basic/main.typ")
project.bufs[bufnr] = true
store.set_buffer(bufnr, project.key)
store.remove(project.key)
assert(
    store.key_for_buffer(bufnr) == nil,
    "safe project removal should clear reverse buffer mappings"
)
