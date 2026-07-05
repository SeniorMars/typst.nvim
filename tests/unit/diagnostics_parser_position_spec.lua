local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local parser = require("typst.diagnostics.parser")
local util = require("typst.core.util")

local dir = typst_test_cache_path("diagnostics-parser")
vim.fn.delete(dir, "rf")
vim.fn.mkdir(dir, "p")
local file = dir .. "/unicode.typ"
vim.fn.writefile({ "alpha", "αβγ", "tab\tline" }, file)
local spaced_dir = dir .. "/space dir"
vim.fn.mkdir(spaced_dir, "p")
local spaced_file = spaced_dir .. "/main file.typ"
vim.fn.writefile({ "one", "two" }, spaced_file)
local unicode_dir = dir .. "/unicode"
vim.fn.mkdir(unicode_dir, "p")
local unicode_path = unicode_dir .. "/α β.typ"
vim.fn.writefile({ "wide" }, unicode_path)

local project = {
    root = dir,
    main = file,
}

local original_readfile = vim.fn.readfile
local read_count = 0
rawset(vim.fn, "readfile", function(target, ...)
    if target == file then
        read_count = read_count + 1
    end
    return original_readfile(target, ...)
end)

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

    local function fixture(name)
        return table.concat(
            vim.fn.readfile(root .. "/tests/fixtures/diagnostics/" .. name),
            "\n"
        )
    end

    local function diagnostics_for(by_buffer, path)
        return by_buffer[vim.fn.bufadd(path)] or {}
    end

    local short = parser.parse(project, fixture("short.txt"))
    local spaced = diagnostics_for(short, spaced_file)
    assert(spaced[1], "short fixture should parse path with spaces")
    assert(
        spaced[1].col == #"two",
        "short fixture should clamp path-with-spaces columns"
    )
    assert(
        spaced[1].message == "short path with spaces",
        "short fixture should preserve diagnostic message"
    )

    local unicode_diags = diagnostics_for(short, unicode_path)
    assert(
        unicode_diags[1]
            and unicode_diags[1].severity == vim.diagnostic.severity.INFO,
        "short fixture should parse Unicode relative paths and severity"
    )
    local missing_path = util.resolve_path("missing.typ", dir)
    local missing = diagnostics_for(short, missing_path)
    assert(
        missing[1] and missing[1].col == 39,
        "missing diagnostic files should keep provider columns"
    )

    local pretty = parser.parse(project, fixture("pretty.txt"))
    local pretty_spaced = diagnostics_for(pretty, spaced_file)
    assert(
        pretty_spaced[1]
            and pretty_spaced[1].message == "pretty path with spaces",
        "pretty fixture should parse Typst location lines"
    )
    assert(
        pretty_spaced[1].col == #"two",
        "pretty fixture should clamp columns for paths with spaces"
    )
    local pretty_context = diagnostics_for(pretty, unicode_path)
    assert(
        pretty_context[1]
            and pretty_context[1].severity == vim.diagnostic.severity.HINT,
        "pretty context fixture should publish hint diagnostics"
    )
    assert(
        pretty_context[1].message == "while importing module",
        "pretty context fixture should preserve context message"
    )

    local windows = parser.parse(project, fixture("windows_paths.txt"))
    local windows_main =
        util.resolve_path([[C:\Users\Typst Project\main.typ]], dir)
    local windows_main_diags = diagnostics_for(windows, windows_main)
    assert(
        windows_main_diags[1] and windows_main_diags[1].col == 49,
        "Windows-looking short paths should keep stable absolute identity"
    )
    assert(
        util.path_key(windows_main) == "c:/users/typst project/main.typ",
        "foreign Windows paths should not be rooted under cwd"
    )
    local windows_chapter =
        util.resolve_path([[C:\Users\Typst Project\chapter.typ]], dir)
    local windows_chapter_diags = diagnostics_for(windows, windows_chapter)
    assert(
        windows_chapter_diags[1]
            and windows_chapter_diags[1].message
                == "windows-looking pretty path",
        "Windows-looking pretty paths should parse"
    )
end, debug.traceback)

vim.fn.readfile = original_readfile

if not ok then
    vim.api.nvim_echo({ { tostring(err), "ErrorMsg" } }, true, {})
    vim.cmd("cquit")
end

vim.cmd("qa!")
