local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local project_services = require("typst.project.services")
local util = require("typst.core.util")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("index-scratch-output"),
})

local function contains(items, predicate)
    for _, item in ipairs(items or {}) do
        if predicate(item) then
            return true
        end
    end
    return false
end

vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "= Scratch Intro <scratch:intro>",
    "See @scratch:intro.",
    "#let local-card(body) = body",
    "// TODO: index unsaved buffers",
})

local project =
    assert(typst.project.attach(bufnr), "scratch index fixture should attach")
assert(
    project.resolutions[bufnr].scratch == true,
    "scratch index fixture should use a scratch project"
)

local collected = assert(
    typst.index.collect({ project = project }),
    "scratch project should collect"
)
assert(
    contains(collected.headings, function(item)
        return item.title == "Scratch Intro"
    end),
    "scratch project index should collect headings from the buffer"
)
assert(
    contains(collected.labels, function(item)
        return item.name == "scratch:intro"
    end),
    "scratch project index should collect labels from the buffer"
)
assert(
    contains(collected.references, function(item)
        return item.reference_target_name == "scratch:intro"
            and item.reference_target == "label"
    end),
    "scratch project index should classify references against scratch labels"
)
assert(
    contains(collected.definitions, function(item)
        return item.name == "local-card"
    end),
    "scratch project index should collect local definitions"
)
assert(
    contains(collected.todos, function(item)
        return item.text:find("index unsaved buffers", 1, true) ~= nil
    end),
    "scratch project index should collect TODOs"
)

local record = assert(
    project_services.index(project).files[util.path_key(project.main)],
    "scratch main should have a persistent file index entry"
)
assert(
    record.version:match("^buffer:%d+$"),
    "scratch index entry should be keyed by buffer changedtick"
)
assert(
    contains(record.headings, function(item)
        return item.title == "Scratch Intro"
    end),
    "scratch file index entry should expose headings directly"
)

local stats = assert(
    project_services.index(project).stats,
    "scratch index should expose stats"
)
local collect_hits = stats.collect_hits
local file_hits = stats.file_hits
local file_misses = stats.file_misses
local stable = typst.index.collect({ project = project })
assert(
    contains(stable.labels, function(item)
        return item.name == "scratch:intro"
    end),
    "cached scratch aggregate should preserve labels"
)
assert(
    stats.collect_hits > collect_hits,
    "unchanged scratch collect should reuse the aggregate cache"
)
assert(
    stats.file_hits > file_hits,
    "unchanged scratch collect should reuse the file cache"
)
assert(
    stats.file_misses == file_misses,
    "unchanged scratch collect should not rescan the buffer"
)

vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
    "= Scratch Followup <scratch:followup>",
})
local edited_misses = stats.file_misses
local updated = typst.index.collect({ project = project })
assert(
    contains(updated.labels, function(item)
        return item.name == "scratch:followup"
    end),
    "edited scratch buffers should invalidate the cached file entry"
)
assert(
    stats.file_misses > edited_misses,
    "edited scratch buffers should be rescanned"
)

vim.cmd("qa!")
