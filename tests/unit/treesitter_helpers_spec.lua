local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local ts = require("typst.core.treesitter")
assert(
    require("typst.core.treesitter") == ts,
    "edit Tree-sitter helper should remain a compatibility shim"
)

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$alpha$" })
local original_get_node = vim.treesitter.get_node
local original_root = ts.root
local original_walk = ts.walk
local walked = false

local math_node = {}
function math_node:type()
    return "math"
end
function math_node:parent()
    return nil
end
function math_node:range()
    return 0, 0, 0, 7
end

local leaf_node = {}
function leaf_node:type()
    return "identifier"
end
function leaf_node:parent()
    return math_node
end
function leaf_node:range()
    return 0, 1, 0, 6
end

local punctuation_node = {}
function punctuation_node:type()
    return "("
end
function punctuation_node:range()
    return 0, 0, 0, 1
end

local child_parent = {}
function child_parent:child_count()
    return 2
end
function child_parent:child(index)
    return ({ punctuation_node, leaf_node })[index + 1]
end

local children = ts.children(child_parent)
assert(
    #children == 2
        and children[1] == punctuation_node
        and children[2] == leaf_node,
    "children should expose child_count/child based nodes, including punctuation"
)
assert(
    ts.first_child(child_parent, "(") == punctuation_node,
    "first_child should find punctuation children"
)
assert(
    ts.first_child(child_parent, "identifier") == leaf_node,
    "first_child should find typed children"
)

local fake_cursor_root = {}
function fake_cursor_root:named_descendant_for_range(row, col)
    assert(row == 0 and col == 2, "node-at-position should use cursor row/col")
    return leaf_node
end

rawset(ts, "root", function(root_bufnr)
    assert(
        root_bufnr == bufnr,
        "node-at-position should use the requested buffer"
    )
    return fake_cursor_root
end)
rawset(ts, "walk", function(...)
    walked = true
    return original_walk(...)
end)
local ok, err = xpcall(function()
    local found = ts.find_containing(bufnr, { "equation", "math" }, { 0, 2 })
    assert(
        found == math_node,
        "find_containing should return the nearest matching ancestor"
    )
    assert(
        not walked,
        "find_containing should not walk the full tree when ancestor lookup succeeds"
    )
end, debug.traceback)

vim.treesitter.get_node = original_get_node
ts.root = original_root
ts.walk = original_walk

if not ok then
    vim.api.nvim_echo({ { tostring(err), "ErrorMsg" } }, true, {})
    vim.cmd("cquit")
end

local original_collect_walk = ts.walk
local collect_walks = 0

local heading_a = {}
function heading_a:type()
    return "heading"
end
function heading_a:range()
    return 1, 0, 1, 8
end

local heading_b = {}
function heading_b:type()
    return "heading"
end
function heading_b:range()
    return 0, 0, 0, 8
end

local fake_root = {}
rawset(ts, "root", function(root_bufnr)
    assert(root_bufnr == bufnr, "collect should parse the requested buffer")
    return fake_root
end)
rawset(ts, "walk", function(_, callback)
    collect_walks = collect_walks + 1
    callback(heading_a)
    callback(heading_b)
end)
local cache_ok, cache_err = xpcall(function()
    ts.forget(bufnr)
    local first = ts.collect(bufnr, "heading")
    local second = ts.collect(bufnr, "heading")
    assert(collect_walks == 1, "collect should reuse cached node lists")
    assert(
        first[1] == heading_b and first[2] == heading_a,
        "collect should keep nodes sorted by source position"
    )
    first[1] = nil
    local third = ts.collect(bufnr, "heading")
    assert(
        third[1] == heading_b and third[2] == heading_a,
        "cached collect results should be returned as caller-owned lists"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$beta$" })
    ts.collect(bufnr, "heading")
    assert(
        collect_walks == 2,
        "collect should invalidate cached node lists after buffer changes"
    )
end, debug.traceback)

ts.root = original_root
ts.walk = original_collect_walk
ts.forget(bufnr)

if not cache_ok then
    vim.api.nvim_echo({ { tostring(cache_err), "ErrorMsg" } }, true, {})
    vim.cmd("cquit")
end

vim.cmd("qa!")
