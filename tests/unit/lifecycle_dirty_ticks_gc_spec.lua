local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local raw_project = require("typst.project")
local core_lifecycle = require("typst.core.lifecycle")
local lifecycle = require("typst.project.lifecycle")
local lifecycle_buffers = require("typst.project.lifecycle.buffers")
local attachments = require("typst.project.attachments")
local project_store = require("typst.project.store")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    project = {
        import_scan = false,
    },
})
vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "= Dirty ticks" })
assert(typst.project.attach(bufnr), "buffer should attach")
vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { "Body" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr, modeline = false })
assert(
    lifecycle_buffers._dirty_tick_count() > 0,
    "TextChanged should record a debounce tick"
)

lifecycle.detach(bufnr)
assert(
    lifecycle_buffers._dirty_tick_count() == 0,
    "buffer detach should forget debounce ticks"
)

vim.cmd.enew()
local raw_detach_bufnr = vim.api.nvim_get_current_buf()
vim.bo[raw_detach_bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(raw_detach_bufnr, 0, -1, false, { "= Raw Detach" })
assert(
    typst.project.attach(raw_detach_bufnr),
    "raw detach buffer should attach"
)
vim.api.nvim_buf_set_lines(raw_detach_bufnr, 1, 1, false, { "Body" })
vim.api.nvim_exec_autocmds(
    "TextChanged",
    { buffer = raw_detach_bufnr, modeline = false }
)
assert(
    lifecycle_buffers._dirty_tick_count() > 0,
    "raw detach setup should record a debounce tick"
)
raw_project.detach(raw_detach_bufnr)
assert(
    lifecycle_buffers._dirty_tick_count() == 0,
    "raw project detach should forget debounce ticks"
)

local project_dir = vim.fn.tempname()
vim.fn.mkdir(project_dir, "p")
local chapter = project_dir .. "/chapter.typ"
local main = project_dir .. "/main.typ"
vim.fn.writefile({ "= Chapter" }, chapter)
vim.fn.writefile({ "= Main", '#include "chapter.typ"' }, main)

vim.cmd.edit(vim.fn.fnameescape(chapter))
local moved_bufnr = vim.api.nvim_get_current_buf()
vim.bo[moved_bufnr].filetype = "typst"
assert(typst.project.attach(moved_bufnr), "real file buffer should attach")
vim.api.nvim_buf_set_lines(moved_bufnr, 1, 1, false, { "Body" })
vim.api.nvim_exec_autocmds(
    "TextChanged",
    { buffer = moved_bufnr, modeline = false }
)
assert(
    lifecycle_buffers._dirty_tick_count() > 0,
    "project transition setup should record a debounce tick"
)
lifecycle.set_main(main, moved_bufnr, { persist = false })
assert(
    lifecycle_buffers._dirty_tick_count() == 0,
    "project transition should forget old project-key debounce ticks"
)

local raw_project_dir = vim.fn.tempname()
vim.fn.mkdir(raw_project_dir, "p")
local raw_chapter = raw_project_dir .. "/chapter.typ"
local raw_main = raw_project_dir .. "/main.typ"
vim.fn.writefile({ "= Chapter" }, raw_chapter)
vim.fn.writefile({ "= Main", '#include "chapter.typ"' }, raw_main)

vim.cmd.edit(vim.fn.fnameescape(raw_chapter))
local raw_moved_bufnr = vim.api.nvim_get_current_buf()
vim.bo[raw_moved_bufnr].filetype = "typst"
assert(
    typst.project.attach(raw_moved_bufnr),
    "raw transfer buffer should attach"
)
vim.api.nvim_buf_set_lines(raw_moved_bufnr, 1, 1, false, { "Body" })
vim.api.nvim_exec_autocmds(
    "TextChanged",
    { buffer = raw_moved_bufnr, modeline = false }
)
assert(
    lifecycle_buffers._dirty_tick_count() > 0,
    "raw project transition setup should record a debounce tick"
)
raw_project.set_main(raw_moved_bufnr, raw_main, { persist = false })
assert(
    lifecycle_buffers._dirty_tick_count() == 0,
    "raw project transfer should forget old project-key debounce ticks"
)

local stale_dir = vim.fn.tempname()
vim.fn.mkdir(stale_dir, "p")
local stale_path = stale_dir .. "/stale.typ"
local stale_main = stale_dir .. "/main.typ"
vim.fn.writefile({ "= Stale" }, stale_path)
vim.fn.writefile({ "= Stale Main" }, stale_main)
vim.cmd.edit(vim.fn.fnameescape(stale_path))
local stale_bufnr = vim.api.nvim_get_current_buf()
vim.bo[stale_bufnr].filetype = "typst"

local stale_key = "missing-project-key"
local stale_forgets = 0
local original_forget = attachments.forget
local original_key_for_buffer = project_store.key_for_buffer
local original_get = project_store.get
local stale_ok, stale_err = xpcall(function()
    rawset(attachments, "forget", function(target_bufnr, key)
        if target_bufnr == stale_bufnr and key == stale_key then
            stale_forgets = stale_forgets + 1
        end
        return original_forget(target_bufnr, key)
    end)
    rawset(project_store, "key_for_buffer", function(target_bufnr)
        if target_bufnr == stale_bufnr then
            return stale_key
        end
        return original_key_for_buffer(target_bufnr)
    end)
    rawset(project_store, "get", function(key)
        if key == stale_key then
            return nil
        end
        return original_get(key)
    end)

    raw_project.commit_attach({
        root = stale_dir,
        main = stale_main,
        bufnr = stale_bufnr,
        path = stale_path,
        resolution = {},
    })
end, debug.traceback)
attachments.forget = original_forget
project_store.key_for_buffer = original_key_for_buffer
project_store.get = original_get
if not stale_ok then
    error(stale_err)
end
assert(
    stale_forgets == 1,
    "raw project transfer should forget known stale project keys"
)

vim.cmd.enew()
local reset_bufnr = vim.api.nvim_get_current_buf()
vim.bo[reset_bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(reset_bufnr, 0, -1, false, { "= Reset ticks" })
assert(typst.project.attach(reset_bufnr), "second buffer should attach")
vim.api.nvim_buf_set_lines(reset_bufnr, 1, 1, false, { "Body" })
vim.api.nvim_exec_autocmds(
    "TextChanged",
    { buffer = reset_bufnr, modeline = false }
)
assert(
    lifecycle_buffers._dirty_tick_count() > 0,
    "second TextChanged should record a debounce tick"
)
typst.reset({ force = true })
assert(
    lifecycle_buffers._dirty_tick_count() == 0,
    "plugin reset should clear all debounce ticks"
)

typst.setup({
    root_markers = {},
    project = {
        import_scan = false,
    },
})
vim.cmd.enew()
local reapply_bufnr = vim.api.nvim_get_current_buf()
vim.bo[reapply_bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(reapply_bufnr, 0, -1, false, { "= Reapply" })
assert(typst.project.attach(reapply_bufnr), "reapply buffer should attach")
local apply_all_calls = 0
local original_apply_all = core_lifecycle.apply_buffer_features_all_windows
local original_apply = core_lifecycle.apply_buffer_features
local reapply_ok, reapply_err = xpcall(function()
    rawset(
        core_lifecycle,
        "apply_buffer_features_all_windows",
        function(target_bufnr, opts)
            if
                target_bufnr == reapply_bufnr
                and opts
                and opts.force == true
            then
                apply_all_calls = apply_all_calls + 1
            end
            return true
        end
    )
    rawset(core_lifecycle, "apply_buffer_features", function()
        error("single-window reapply path should not be used")
    end)
    lifecycle_buffers.reapply_attached_buffers()
end, debug.traceback)
core_lifecycle.apply_buffer_features_all_windows = original_apply_all
core_lifecycle.apply_buffer_features = original_apply
if not reapply_ok then
    error(reapply_err)
end
assert(
    apply_all_calls == 1,
    "reapply should use the all-windows buffer feature helper"
)
