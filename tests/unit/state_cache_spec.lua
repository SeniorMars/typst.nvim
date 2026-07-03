local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local conceal = require("typst.conceal")
local metadata = require("typst.metadata")
local registry = require("typst.project")
local project_store = require("typst.project.store")
local state_store = require("typst.core.state")
local util = require("typst.core.util")

typst.reset()
local reload_preview_stopped = 0
local reload_preview_project = nil
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("state-cache-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function(project_to_stop)
            reload_preview_stopped = reload_preview_stopped + 1
            reload_preview_project = project_to_stop
            return true
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
local chapter = root .. "/tests/fixtures/basic/chapter.typ"

vim.cmd.edit(chapter)
vim.b.typst_main = main
local project = typst.project.attach(0)
assert(
    project.main == main,
    "initial attached project should use buffer main override"
)

local _, info_lines, info_buf = typst.ui.info({ bang = true })
assert(
    info_lines[1] == "typst.nvim",
    "info bang should build detailed info lines"
)
assert(
    vim.api.nvim_buf_is_valid(info_buf),
    "info bang should open an info buffer"
)
assert(
    vim.bo[info_buf].filetype == "typstinfo",
    "info bang should use typstinfo filetype"
)

vim.cmd.buffer(vim.fn.bufnr(chapter))
vim.cmd("TypstInfo!")
assert(
    vim.bo[vim.api.nvim_get_current_buf()].filetype == "typstinfo",
    "TypstInfo! should open an info buffer"
)
vim.cmd.buffer(vim.fn.bufnr(chapter))

local detached_event = nil
local attached_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstProjectDetach",
    callback = function(args)
        detached_event = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstProjectAttach",
    callback = function(args)
        attached_event = args.data
    end,
})

assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "reload_state fixture should open a preview"
)
assert(
    typst_test_preview(project).active == true,
    "initial project should track active preview before reload"
)

vim.b.typst_main = chapter
local reloaded = typst.project.reload_state({ notify = false })
assert(
    reloaded.main == chapter,
    "reload_state should re-resolve the current buffer state"
)
assert(
    detached_event and detached_event.main == main,
    "reload_state should emit detach for previous state"
)
assert(
    attached_event and attached_event.main == chapter,
    "reload_state should emit attach for new state"
)
assert(
    reload_preview_stopped == 1,
    "reload_state should stop previews from the old project"
)
assert(
    reload_preview_project and reload_preview_project.key == project.key,
    "reload_state preview cleanup should receive the old project"
)
assert(
    typst_test_preview(project).active == false,
    "reload_state should clear old project preview state"
)
assert(
    project_store.all()[project.key] == nil,
    "reload_state should prune the old preview project"
)

local before_generation = conceal.generation()
local before_catalog = metadata.catalog()
local cleared = typst.project.clear_cache({ notify = false })
local after_catalog = metadata.catalog()
assert(
    cleared.metadata
        and cleared.completion
        and cleared.package
        and cleared.symbol
        and cleared.index
        and cleared.import_scan
        and cleared.treesitter
        and cleared.conceal,
    "clear_cache should report cleared caches"
)
assert(
    conceal.generation() > before_generation,
    "clear_cache should invalidate conceal cache generation"
)
assert(
    after_catalog ~= before_catalog,
    "clear_cache should invalidate metadata catalog cache"
)

vim.cmd("TypstClearCache")
assert(
    conceal.generation() > before_generation + 1,
    "TypstClearCache command should refresh conceal generation"
)

vim.cmd.buffer(vim.fn.bufnr(chapter))
vim.cmd("TypstReloadState")
assert(
    typst.ui.status().main == chapter,
    "TypstReloadState command should keep the reloaded main"
)

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("state-cache-output"),
    project = {
        import_scan = false,
        persist_main = true,
    },
})

local persisted_root = vim.fn.tempname()
vim.fn.mkdir(persisted_root, "p")
local persisted_main = persisted_root .. "/document.typ"
local persisted_chapter = persisted_root .. "/chapter.typ"
vim.fn.writefile(
    { "= Persisted main", '#include "chapter.typ"' },
    persisted_main
)
vim.fn.writefile({ "= Persisted chapter" }, persisted_chapter)

vim.cmd.edit(vim.fn.fnameescape(persisted_chapter))
vim.b.typst_main = nil
vim.cmd("TypstSetMain " .. vim.fn.fnameescape(persisted_main))
assert(
    typst.ui.status().main == util.normalize(persisted_main),
    "TypstSetMain should use the requested main"
)

pcall(vim.api.nvim_buf_del_var, 0, "typst_main")
typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("state-cache-output"),
    project = {
        import_scan = false,
        persist_main = true,
    },
})

local persisted_project = typst.project.attach(0)
assert(
    persisted_project.main == util.normalize(persisted_main),
    "saved explicit main should survive a reset"
)
assert(
    persisted_project.resolutions[vim.api.nvim_get_current_buf()].main_source
        == "saved explicit main",
    "saved explicit main should identify its resolution source"
)

local renamed_chapter = persisted_root .. "/renamed-chapter.typ"
vim.cmd("silent saveas " .. vim.fn.fnameescape(renamed_chapter))
assert(
    typst.ui.status().main == util.normalize(persisted_main),
    "renamed buffer should keep its explicit main"
)
assert(
    state_store.explicit_main(persisted_chapter) == nil,
    "BufFilePost should move saved main off the old path"
)

pcall(vim.api.nvim_buf_del_var, 0, "typst_main")
typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("state-cache-output"),
    project = {
        import_scan = false,
        persist_main = true,
    },
})

local renamed_project = typst.project.attach(0)
assert(
    renamed_project.main == util.normalize(persisted_main),
    "saved explicit main should follow :saveas"
)
assert(
    renamed_project.resolutions[vim.api.nvim_get_current_buf()].main_source
        == "saved explicit main",
    "renamed saved explicit main should identify its resolution source"
)

state_store.clear_explicit_main(renamed_chapter)
pcall(vim.api.nvim_buf_del_var, 0, "typst_main")
typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("state-cache-output"),
    project = {
        import_scan = false,
        persist_main = true,
    },
})

local cleared_project = typst.project.attach(0)
assert(
    cleared_project.main == util.normalize(renamed_chapter),
    "cleared explicit main should restore fallback resolution"
)

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("state-cache-output"),
    project = {
        import_scan = false,
        persist_main = false,
    },
})

local transient_root = vim.fn.tempname()
vim.fn.mkdir(transient_root, "p")
local transient_main = transient_root .. "/document.typ"
local transient_chapter = transient_root .. "/chapter.typ"
vim.fn.writefile(
    { "= Transient main", '#include "chapter.typ"' },
    transient_main
)
vim.fn.writefile({ "= Transient chapter" }, transient_chapter)

vim.cmd.edit(vim.fn.fnameescape(transient_chapter))
vim.b.typst_main = nil
vim.cmd("TypstSetMain " .. vim.fn.fnameescape(transient_main))
assert(
    typst.ui.status().main == util.normalize(transient_main),
    "TypstSetMain should still update the live main"
)

pcall(vim.api.nvim_buf_del_var, 0, "typst_main")
typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("state-cache-output"),
    project = {
        import_scan = false,
        persist_main = true,
    },
})

local transient_project = typst.project.attach(0)
assert(
    transient_project.main == util.normalize(transient_chapter),
    "TypstSetMain should not write saved state when project.persist_main=false"
)

vim.cmd("qa!")
