local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local parser = require("typst.bibliography.parser")

local uv = vim.uv or vim.loop
local original_fs_stat = uv.fs_stat
local original_readfile = vim.fn.readfile

local path = typst_test_cache_path("bibliography-parser-cache/refs.bib")
local large_path =
    typst_test_cache_path("bibliography-parser-cache/large-refs.bib")
local signature = 1
local reads = 0
local large_reads = 0
local lines = {
    "@article{first,",
    "  title = {First},",
    "}",
}
local large_lines = {}
for index = 1, 320 do
    large_lines[#large_lines + 1] = ("@article{large-%03d,"):format(index)
    large_lines[#large_lines + 1] = ("  title = {Large Entry %03d},"):format(
        index
    )
    large_lines[#large_lines + 1] = "}"
end
vim.fn.mkdir(vim.fn.fnamemodify(large_path, ":h"), "p")
vim.fn.writefile(large_lines, large_path)

local ok, err = xpcall(function()
    parser.reset()
    rawset(uv, "fs_stat", function(target)
        if target == path then
            return {
                size = signature,
                mtime = {
                    sec = signature,
                    nsec = 0,
                },
            }
        end
        return original_fs_stat(target)
    end)
    rawset(vim.fn, "readfile", function(target, ...)
        if target == path then
            reads = reads + 1
            return vim.deepcopy(lines)
        end
        if target == large_path then
            large_reads = large_reads + 1
        end
        return original_readfile(target, ...)
    end)

    local first = parser.parse_bibtex_file(path)
    assert(
        first[1] and first[1].key == "first",
        "first parse should read bib entry"
    )
    parser.parse_bibtex_file(path)
    assert(
        reads == 1,
        "unchanged bibliography signature should reuse scan cache"
    )

    signature = 2
    lines = {
        "@article{second,",
        "  title = {Second},",
        "}",
    }
    local second = parser.parse_bibtex_file(path)
    assert(
        second[1] and second[1].key == "second",
        "changed bibliography signature should rescan"
    )
    assert(reads == 2, "signature change should read bibliography again")

    parser.reset()
    parser.parse_bibtex_file(path)
    assert(reads == 3, "parser reset should clear bibliography scan cache")

    parser.reset()
    local large_first = parser.parse_bibtex_file(large_path)
    assert(
        #large_first == 320 and large_first[320].key == "large-320",
        "large bibliography fixture should parse all entries"
    )
    parser.parse_bibtex_file(large_path)
    assert(
        large_reads == 1,
        "large bibliography file should reuse cache while stat is unchanged"
    )

    vim.cmd.edit(vim.fn.fnameescape(large_path))
    local large_buf = vim.api.nvim_get_current_buf()
    vim.bo[large_buf].filetype = "bib"
    vim.api.nvim_buf_set_lines(large_buf, 0, -1, false, {
        "@article{unsaved-large,",
        "  title = {Unsaved Large},",
        "}",
    })
    local loaded_first = parser.parse_bibtex_file(large_path)
    assert(
        loaded_first[1] and loaded_first[1].key == "unsaved-large",
        "loaded bibliography buffer should take precedence over disk cache"
    )
    assert(
        large_reads == 1,
        "loaded bibliography buffer should not reread the large disk file"
    )

    vim.api.nvim_buf_set_lines(large_buf, 0, -1, false, {
        "@article{changed-large,",
        "  title = {Changed Large},",
        "}",
    })
    local loaded_changed = parser.parse_bibtex_file(large_path)
    assert(
        loaded_changed[1] and loaded_changed[1].key == "changed-large",
        "loaded bibliography cache should invalidate by changedtick"
    )
end, debug.traceback)

uv.fs_stat = original_fs_stat
vim.fn.readfile = original_readfile
parser.reset()

if not ok then
    error(err)
end
