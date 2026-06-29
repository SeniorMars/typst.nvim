local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

for module_name in pairs(package.loaded) do
    if
        module_name == "typst.completion"
        or module_name:find("^typst%.completion%.")
        or module_name == "typst.metadata"
    then
        package.loaded[module_name] = nil
    end
end

local completion = require("typst.completion")

for _, module_name in ipairs({
    "typst.completion.packages",
    "typst.completion.project",
    "typst.completion.fonts",
    "typst.completion.paths",
    "typst.completion.csl",
    "typst.completion.raw",
    "typst.completion.lsp",
    "typst.metadata",
}) do
    assert(
        package.loaded[module_name] == nil,
        ("requiring completion facade should not load %s"):format(module_name)
    )
end

local items = completion.complete({
    context = "raw_language",
    base = "",
    limit = 5,
})
assert(type(items) == "table", "raw-language completion should return items")
assert(
    package.loaded["typst.completion.raw"] ~= nil,
    "raw-language completion should load only the raw source it needs"
)
assert(
    package.loaded["typst.completion.packages"] == nil,
    "raw-language completion should not load package completion"
)
assert(
    package.loaded["typst.completion.fonts"] == nil,
    "raw-language completion should not load font completion"
)
assert(
    package.loaded["typst.completion.paths"] == nil,
    "raw-language completion should not load path completion"
)
assert(
    package.loaded["typst.completion.lsp"] == nil,
    "raw-language completion should not load Tinymist/LSP completion"
)
assert(
    package.loaded["typst.metadata"] == nil,
    "raw-language completion should not load the metadata catalog"
)

completion.reset()

local scan_root = typst_test_cache_path("completion-lazy-path")
vim.fn.delete(scan_root, "rf")
vim.fn.mkdir(scan_root, "p")
package.loaded["typst.completion.lsp"] = nil
package.loaded["typst.metadata"] = nil
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, scan_root .. "/main.typ")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '#import ""' })
vim.api.nvim_set_current_buf(bufnr)

local original_dir = vim.fs.dir
local ok, err = xpcall(function()
    vim.fs.dir = function(path)
        assert(path == scan_root, "path completion should scan buffer dir")
        local done = false
        return function()
            if done then
                return nil
            end
            done = true
            return "chapter.typ", "file"
        end
    end

    items = completion.complete({
        context = "path",
        bufnr = bufnr,
        base = "",
        pos = { 0, 9 },
        limit = 5,
    })
    assert(type(items) == "table", "path completion should return items")
    assert(
        package.loaded["typst.completion.paths"] ~= nil,
        "path completion should load only the path source it needs"
    )
    assert(
        package.loaded["typst.completion.lsp"] == nil,
        "path completion should not load Tinymist/LSP completion"
    )
    assert(
        package.loaded["typst.metadata"] == nil,
        "path completion should not load the metadata catalog"
    )
end, debug.traceback)
vim.fs.dir = original_dir
assert(ok, err)

vim.cmd("qa!")
