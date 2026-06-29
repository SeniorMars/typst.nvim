local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local parser = require("typst.bibliography.parser")

local uv = vim.uv or vim.loop
local original_fs_stat = uv.fs_stat
local original_readfile = vim.fn.readfile

local path = typst_test_cache_path("bibliography-parser-cache/refs.bib")
local signature = 1
local reads = 0
local lines = {
    "@article{first,",
    "  title = {First},",
    "}",
}

local ok, err = xpcall(function()
    parser.reset()
    uv.fs_stat = function(target)
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
    end
    vim.fn.readfile = function(target, ...)
        if target == path then
            reads = reads + 1
            return vim.deepcopy(lines)
        end
        return original_readfile(target, ...)
    end

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
end, debug.traceback)

uv.fs_stat = original_fs_stat
vim.fn.readfile = original_readfile
parser.reset()

if not ok then
    error(err)
end
