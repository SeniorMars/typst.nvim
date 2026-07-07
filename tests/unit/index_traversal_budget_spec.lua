local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_services = require("typst.project.services")
local store = require("typst.project.store")
local typst = require("typst")
local util = require("typst.core.util")

local function write_project(name, files)
    local dir = typst_test_cache_path(name)
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p")
    for path, lines in pairs(files) do
        local full = vim.fs.joinpath(dir, path)
        vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
        vim.fn.writefile(lines, full)
    end
    return dir, util.normalize(vim.fs.joinpath(dir, "main.typ"))
end

local function collect_with_index(name, index_config, files)
    typst.reset({ force = true })
    local dir, main = write_project(name, files)
    typst.setup({
        root = dir,
        root_markers = {},
        output_dir = typst_test_cache_path(name .. "-output"),
        project = {
            index = index_config,
        },
    })
    vim.cmd.edit(vim.fn.fnameescape(main))
    vim.bo.filetype = "typst"
    local snapshot = assert(typst.project.set_main(main))
    local project = assert(store.get(snapshot.key))
    local collected = assert(typst.index.collect({ project = project }))
    local project_index = assert(project_services.index(project))
    return collected, project_index, dir
end

local _, max_files_index, max_files_dir = collect_with_index(
    "index-traversal-max-files",
    {
        max_files = 1,
        max_entries = 16,
        max_depth = 16,
    },
    {
        ["main.typ"] = { "= Main", '#include "a.typ"' },
        ["a.typ"] = { "= A" },
    }
)
assert(
    max_files_index.traversal.partial == true,
    "max_files budget should mark the index partial"
)
assert(
    max_files_index.traversal.partial_reason == "max_files",
    "max_files budget should report max_files"
)
assert(
    max_files_index.traversal.scanned_files == 1,
    "max_files budget should cap scanned file count"
)
assert(
    util.same_path(
        max_files_index.traversal.first_skipped_path,
        vim.fs.joinpath(max_files_dir, "a.typ")
    ),
    "max_files budget should report the first skipped file"
)

local _, max_depth_index = collect_with_index("index-traversal-max-depth", {
    max_files = 16,
    max_entries = 16,
    max_depth = 0,
}, {
    ["main.typ"] = { "= Main", '#include "a.typ"' },
    ["a.typ"] = { "= A" },
})
assert(
    max_depth_index.traversal.partial == true,
    "max_depth budget should mark the index partial"
)
assert(
    max_depth_index.traversal.partial_reason == "max_depth",
    "max_depth budget should report max_depth"
)
assert(
    max_depth_index.traversal.scanned_files == 1,
    "max_depth zero should only scan initial files"
)

local _, max_entries_index, max_entries_dir = collect_with_index(
    "index-traversal-max-entries",
    {
        max_files = 16,
        max_entries = 1,
        max_depth = 16,
    },
    {
        ["main.typ"] = {
            "= Main",
            '#include "a.typ"',
            '#include "b.typ"',
        },
        ["a.typ"] = { "= A" },
        ["b.typ"] = { "= B" },
    }
)
assert(
    max_entries_index.traversal.partial == true,
    "max_entries budget should mark the index partial"
)
assert(
    max_entries_index.traversal.partial_reason == "max_entries",
    "max_entries budget should report max_entries"
)
assert(
    max_entries_index.traversal.import_entries == 2,
    "max_entries budget should record import entries considered"
)
assert(
    util.same_path(
        max_entries_index.traversal.first_skipped_path,
        vim.fs.joinpath(max_entries_dir, "b.typ")
    ),
    "max_entries budget should report the first skipped import"
)

vim.cmd("qa!")
