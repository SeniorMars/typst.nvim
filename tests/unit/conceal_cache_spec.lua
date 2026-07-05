local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function make_node(row, start_col, end_col)
    local node = {
        row = row,
        start_col = start_col,
        end_col = end_col,
    }

    function node:range()
        return self.row, self.start_col, self.row, self.end_col
    end

    function node:type()
        return "$"
    end

    function node:parent()
        return nil
    end

    function node:child_count()
        return 0
    end

    function node:iter_children()
        return function() end
    end

    return node
end

local fake_root = {
    row = 0,
}

function fake_root:range()
    return 0, 0, 320, 0
end

function fake_root:type()
    return "source_file"
end

function fake_root:child_count()
    return 0
end

function fake_root:named_child_count()
    return 0
end

function fake_root:iter_children()
    return function() end
end

local fake_nodes = {
    make_node(10, 0, 1),
    make_node(140, 0, 1),
    make_node(260, 0, 1),
}

local query_calls = {}
local fake_query = {
    captures = {
        "conceal.math_delimiter",
    },
}

function fake_query:iter_captures(_, _, start_row, end_row)
    query_calls[#query_calls + 1] = {
        start_row = start_row,
        end_row = end_row,
    }

    local index = 0
    return function()
        index = index + 1
        while fake_nodes[index] do
            local node = fake_nodes[index]
            if
                node.row >= start_row and (end_row < 0 or node.row < end_row)
            then
                return 1, node
            end
            index = index + 1
        end
    end
end

local ts = require("typst.core.treesitter")
local old_root = ts.root
rawset(ts, "root", function()
    return fake_root
end)
local old_query_get = vim.treesitter.query.get
local query_loads = 0
rawset(vim.treesitter.query, "get", function(lang, name)
    assert(lang == "typst", "conceal cache spec should request Typst queries")
    assert(
        name == "conceal",
        "conceal cache spec should request the conceal query"
    )
    query_loads = query_loads + 1
    if query_loads == 1 then
        error("temporary missing conceal query")
    end
    return fake_query
end)

local config = require("typst.config")
config.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-cache-output"),
})
local conceal = require("typst.conceal")
conceal.reset()

local bufnr = vim.api.nvim_create_buf(false, true)
local lines = {}
for index = 1, 320 do
    lines[index] = "."
end
lines[11] = "$"
lines[141] = "$"
lines[261] = "$"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.bo[bufnr].filetype = "typst"

local missed = conceal.matches(bufnr, { start_row = 130, end_row = 141 })
assert(
    #missed == 0 and query_loads == 1,
    "temporary conceal query load failure should return no matches"
)

local middle = conceal.matches(bufnr, { start_row = 130, end_row = 141 })
assert(
    #middle == 1 and middle[1].source.start_row == 140,
    "conceal should retry query loading after a temporary failure"
)
assert(
    query_loads == 2,
    "conceal query should be requested again after failure"
)
assert(#query_calls == 1, "first range request should query one chunk")
assert(
    query_calls[1].start_row == 127 and query_calls[1].end_row == 257,
    "middle range should query its padded fixed-size chunk"
)

local stable = conceal.matches(bufnr, { start_row = 130, end_row = 141 })
assert(
    #stable == 1 and #query_calls == 1,
    "stable range requests should reuse cached chunk matches"
)

local first = conceal.matches(bufnr, { start_row = 10, end_row = 11 })
assert(
    #first == 1 and first[1].source.start_row == 10,
    "separate ranges should query their own chunks"
)
assert(#query_calls == 2, "second uncached chunk should add one query")
assert(
    query_calls[2].start_row == 0 and query_calls[2].end_row == 129,
    "top chunk should be padded only at the end"
)

local all = conceal.matches(bufnr)
assert(#all == 3, "full-buffer callers should still receive all matches")
assert(
    #query_calls == 3,
    "full-buffer callers should reuse cached chunks and query missing chunks only"
)
assert(
    query_calls[3].start_row == 255 and query_calls[3].end_row == 320,
    "tail chunk should be range-limited"
)

for _, call in ipairs(query_calls) do
    assert(
        call.start_row ~= 0
            or call.end_row ~= vim.api.nvim_buf_line_count(bufnr),
        "conceal should not issue full-buffer Tree-sitter queries for chunked matches"
    )
end

local match_cache = require("typst.conceal.matches")
local before_invalidation = #query_calls
assert(
    match_cache.invalidate_ranges(bufnr, { { 130, 0, 141, 0 } }),
    "changed-tree ranges should invalidate cached conceal chunks"
)
local requeried_middle =
    conceal.matches(bufnr, { start_row = 130, end_row = 141 })
assert(
    #requeried_middle == 1 and #query_calls == before_invalidation + 1,
    "changed-tree invalidation should requery the intersecting chunk"
)
local cached_top = conceal.matches(bufnr, { start_row = 10, end_row = 11 })
assert(
    #cached_top == 1 and #query_calls == before_invalidation + 1,
    "changed-tree invalidation should preserve unaffected cached chunks"
)

local before_node_range_invalidation = #query_calls
assert(
    match_cache.invalidate_ranges(bufnr, { { 140, 0, 999, 140, 1, 1000 } }),
    "node-range changed-tree tuples should invalidate cached conceal chunks"
)
local requeried_node_range =
    conceal.matches(bufnr, { start_row = 130, end_row = 141 })
assert(
    #requeried_node_range == 1
        and #query_calls == before_node_range_invalidation + 1,
    "six-field node ranges should use the fourth field as end row"
)
local cached_tail_after_node_range =
    conceal.matches(bufnr, { start_row = 260, end_row = 261 })
assert(
    #cached_tail_after_node_range == 1
        and #query_calls == before_node_range_invalidation + 1,
    "node-range byte offsets should not be treated as end rows"
)

vim.api.nvim_win_set_buf(0, bufnr)
conceal.register("math", "phase0-custom", "∗")
local render = require("typst.conceal.render")
local old_window = render.window_matches
local seen_custom_conceal = nil
rawset(render, "window_matches", function(_, _, _, custom_conceal)
    seen_custom_conceal = custom_conceal
    return {}
end)
conceal._window_matches(bufnr, 0, {})
assert(
    seen_custom_conceal
        and seen_custom_conceal.math
        and seen_custom_conceal.math["phase0-custom"] == "∗",
    "window match helper should pass registered custom conceal values"
)
render.window_matches = old_window
conceal.unregister("math", "phase0-custom")

vim.treesitter.query.get = old_query_get
ts.root = old_root
conceal.reset()
vim.cmd("qa!")
