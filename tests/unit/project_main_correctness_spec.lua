local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local main_file = require("typst.project.main_file")
local resolver = require("typst.project.resolver")
local typst = require("typst")

local fixture_root = typst_test_cache_path(
    ("project-main-correctness-%d"):format(vim.uv.hrtime())
)
local chapter_dir = fixture_root .. "/chapters"
vim.fn.mkdir(chapter_dir, "p")

local main = fixture_root .. "/main.typ"
local leaf = chapter_dir .. "/intro.typ"
vim.fn.writefile({ "= Main" }, main)
vim.fn.writefile({ '#import "../main.typ"' }, leaf)

typst.reset()
typst.setup({
    main = "../main.typ",
})
vim.cmd.edit(leaf)
local candidate = resolver.resolve_candidate(vim.api.nvim_get_current_buf())
assert(
    candidate.main == main,
    "configured relative main should resolve against the initial buffer root"
)
assert(
    candidate.root == fixture_root,
    "configured main outside a buffer-directory root should widen to the common root"
)

typst.reset()
typst.setup({
    root = chapter_dir,
    main = "../main.typ",
})
candidate = resolver.resolve_candidate(vim.api.nvim_get_current_buf())
assert(
    candidate.root == chapter_dir,
    "explicit config.root should not be widened by configured main"
)

local hash_main = fixture_root .. "/my # file.typ"
vim.fn.writefile({ "= Hash" }, hash_main)
vim.fn.writefile({ [["my # file.typ"]] }, fixture_root .. "/.typstmain")
local project_main = select(1, main_file.project_file(leaf))
assert(
    project_main == hash_main,
    ".typstmain should preserve # characters inside quoted paths"
)

vim.cmd("qa!")
