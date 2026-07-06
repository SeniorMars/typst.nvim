local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local count = require("typst.diagnostics.count")
local graph_sources = require("typst.project.graph.sources")
local project_store = require("typst.project.store")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
    project = {
        index = {
            max_file_bytes = 32,
            large_file_policy = "skip",
        },
    },
})

local fixture_root = typst_test_cache_path("count-large-file-policy")
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
local large = fixture_root .. "/large.typ"
vim.fn.writefile({ "= Main", "small words" }, main)
vim.fn.writefile({
    ("large word "):rep(100),
}, large)

local project = project_store.create(fixture_root, main)
graph_sources.add(project, main, "explicit")
graph_sources.add(project, large, "explicit")

local skipped = assert(count.project(project))
assert(skipped.scope == "project", "project count should succeed")
assert(skipped.files == 1, "large unloaded file should be skipped by default")
assert(skipped.skipped_count == 1, "large-file skip should be reported")
assert(
    skipped.skipped_files[large]
        and skipped.skipped_files[large].reason == "large_file",
    "skipped file metadata should include the large-file reason"
)
assert(
    count.format(skipped):find("skipped=1", 1, true),
    "formatted count should report skipped files"
)

local scanned = assert(count.project(project, {
    max_file_bytes = 32,
    large_file_policy = "scan",
}))
assert(scanned.files == 2, "scan policy should read oversized files")
assert(
    scanned.skipped_count == 0,
    "scan policy should not report skipped files"
)
assert(scanned.words > skipped.words, "scan policy should include large prose")

local unknown_policy = assert(count.project(project, {
    max_file_bytes = 32,
    large_file_policy = "future-policy",
}))
assert(
    unknown_policy.files == 1,
    "unknown count large-file policies should default to skip"
)
assert(
    unknown_policy.skipped_count == 1,
    "unknown count large-file policies should report skipped files"
)

local large_bufnr = vim.fn.bufadd(large)
vim.fn.bufload(large_bufnr)
local loaded_large = assert(count.project(project, {
    max_file_bytes = 32,
    large_file_policy = "skip",
}))
assert(
    loaded_large.files == 2,
    "loaded large buffers should be counted without a disk-read skip"
)
assert(
    loaded_large.skipped_count == 0,
    "loaded large buffers should not be reported as skipped"
)

vim.api.nvim_buf_delete(large_bufnr, { force = true })
local race = fixture_root .. "/race.typ"
vim.fn.writefile({ "race words" }, race)
graph_sources.add(project, race, "explicit")
local read_race = assert(count.project(project, {
    max_file_bytes = 0,
    large_file_policy = "scan",
    readfile = function(path)
        if tostring(path):match("race%.typ$") then
            error("read race")
        end
        return vim.fn.readfile(path)
    end,
}))
assert(read_race.files >= 1, "read failures should not abort project count")
assert(
    read_race.skipped_files[race]
        and read_race.skipped_files[race].reason == "read_failed",
    "read failures should be reported as skipped metadata"
)

typst.reset({ force = true })
vim.cmd("qa!")
