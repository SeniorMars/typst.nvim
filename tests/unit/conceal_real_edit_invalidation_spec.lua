local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-real-edit-output"),
})

local conceal = require("typst.conceal")
local match_query = require("typst.conceal.match_query")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typst"

local lines = {}
for index = 1, 260 do
    lines[index] = "."
end
lines[11] = "$ alpha $"
lines[141] = "$ beta $"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

local parser = vim.treesitter.get_parser(bufnr, "typst")
parser:parse()

local old_query = match_query.query
local query_calls = {}
match_query.query = function(query_bufnr, start_row, end_row, custom_conceal)
    query_calls[#query_calls + 1] = {
        start_row = start_row,
        end_row = end_row,
    }
    return old_query(query_bufnr, start_row, end_row, custom_conceal)
end

local function has_source(items, source)
    for _, match in ipairs(items or {}) do
        if match.source_text == source then
            return true
        end
    end
    return false
end

local ok, err = xpcall(function()
    local top = conceal.matches(bufnr, { start_row = 10, end_row = 11 })
    local middle = conceal.matches(bufnr, { start_row = 140, end_row = 141 })
    assert(has_source(top, "alpha"), "top chunk should initially conceal alpha")
    assert(
        has_source(middle, "beta"),
        "middle chunk should initially conceal beta"
    )

    local primed_calls = #query_calls
    assert(primed_calls == 2, "test should prime two conceal chunks")
    conceal.matches(bufnr, { start_row = 10, end_row = 11 })
    conceal.matches(bufnr, { start_row = 140, end_row = 141 })
    assert(
        #query_calls == primed_calls,
        "primed chunks should be cached before edits"
    )

    vim.api.nvim_buf_set_lines(bufnr, 140, 141, false, { "$ gamma $" })
    parser:parse()

    local top_after_edit =
        conceal.matches(bufnr, { start_row = 10, end_row = 11 })
    assert(
        has_source(top_after_edit, "alpha"),
        "same-line edit in another chunk should preserve top conceal"
    )
    assert(
        #query_calls == primed_calls,
        "same-line edit should preserve unaffected cached chunks"
    )

    local middle_after_edit =
        conceal.matches(bufnr, { start_row = 140, end_row = 141 })
    assert(
        has_source(middle_after_edit, "gamma"),
        "same-line edit should update affected conceal chunk"
    )
    assert(
        not has_source(middle_after_edit, "beta"),
        "same-line edit should not leave stale conceal matches"
    )
    assert(
        #query_calls == primed_calls + 1,
        "same-line edit should requery only the affected chunk"
    )

    local calls_before_insert = #query_calls
    conceal.matches(bufnr, { start_row = 10, end_row = 11 })
    conceal.matches(bufnr, { start_row = 140, end_row = 141 })
    assert(
        #query_calls == calls_before_insert,
        "chunks should be cached again after affected requery"
    )

    vim.api.nvim_buf_set_lines(bufnr, 127, 127, false, { "." })
    parser:parse()

    local shifted_middle =
        conceal.matches(bufnr, { start_row = 141, end_row = 142 })
    assert(
        has_source(shifted_middle, "gamma"),
        "line insert should update shifted later chunks without manual refresh"
    )
    assert(
        #query_calls > calls_before_insert,
        "line insert should invalidate shifted chunks at and after the edit"
    )
end, debug.traceback)

match_query.query = old_query

if not ok then
    error(err)
end

vim.cmd("qa!")
