local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("files-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
local chapter = root .. "/tests/fixtures/basic/chapter.typ"
local appendix = root .. "/tests/fixtures/basic/appendix.typ"

vim.cmd.edit(main)
local project = typst.project.set_main(main)

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before files test")
    done = true
end)

assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before files test"
)

vim.cmd.edit(chapter)
assert(
    typst.project.get(0).key == project.key,
    "chapter should resolve to the compiled main project"
)

local items = typst.navigation.files({ open = false })
assert(
    #items >= 3,
    "project files should include main and discovered dependencies"
)

local by_path = {}
for _, item in ipairs(items) do
    by_path[item.filename] = item
end

assert(by_path[main], "project files should include the main file")
assert(by_path[chapter], "project files should include the chapter dependency")
assert(
    by_path[appendix],
    "project files should include the appendix dependency"
)
assert(
    items[1].filename == main,
    "project files should list the main file first"
)
assert(items[1].text:match("^%[main%]"), "main file item should be labeled")
assert(
    by_path[chapter].text:match("^%[buffer%]"),
    "attached chapter item should be labeled as a buffer"
)
assert(
    by_path[appendix].text:match("^%[dependency%]"),
    "unattached appendix item should be labeled as a dependency"
)

local qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(
    qf.title:match("typst.nvim files"),
    "TypstFiles quickfix list should have a project title"
)
assert(
    #qf.items == #items,
    "TypstFiles quickfix list should contain returned items"
)

vim.cmd("qa!")
