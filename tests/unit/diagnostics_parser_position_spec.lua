local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local parser = require("typst.diagnostics.parser")

local dir = typst_test_cache_path("diagnostics-parser")
vim.fn.delete(dir, "rf")
vim.fn.mkdir(dir, "p")
local file = dir .. "/unicode.typ"
vim.fn.writefile({ "alpha", "αβγ", "tab\tline" }, file)

local project = {
    root = dir,
    main = file,
}

local original_readfile = vim.fn.readfile
local read_count = 0
vim.fn.readfile = function(target, ...)
    if target == file then
        read_count = read_count + 1
    end
    return original_readfile(target, ...)
end

local ok, err = xpcall(function()
    local by_buffer = parser.parse(
        project,
        table.concat({
            "unicode.typ:2:99: error: utf8 clamp",
            "unicode.typ:2:2: warning: utf8 byte col",
            "unicode.typ:3:5: error: tab col",
        }, "\n")
    )

    local bufnr = vim.fn.bufadd(file)
    local diagnostics = by_buffer[bufnr]
    assert(diagnostics and #diagnostics == 3, "expected three diagnostics")
    assert(
        diagnostics[1].col == #"αβγ",
        "UTF-8 line clamp should use byte length"
    )
    assert(diagnostics[2].col == 1, "1-based column should become 0-based")
    assert(diagnostics[3].col == 4, "tab columns should stay byte-indexed")
    assert(read_count == 1, "diagnostic parser should read each file once")

    vim.cmd.edit(file)
    local loaded = vim.api.nvim_get_current_buf()
    local reused_opts = { source = "typst-test" }
    vim.api.nvim_buf_set_lines(loaded, 0, -1, false, { "abc" })
    local first =
        parser.parse(project, "unicode.typ:1:99: error: first", reused_opts)
    assert(first[loaded][1].col == 3, "first loaded-buffer parse should clamp")

    vim.api.nvim_buf_set_lines(loaded, 0, -1, false, { "abcdef" })
    local second =
        parser.parse(project, "unicode.typ:1:99: error: second", reused_opts)
    assert(
        second[loaded][1].col == 6,
        "reused opts should not retain stale loaded-buffer lines"
    )
end, debug.traceback)

vim.fn.readfile = original_readfile

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit")
end

vim.cmd("qa!")
