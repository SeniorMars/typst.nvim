local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function make_node(row)
    local node = {
        row = row,
    }

    function node:range()
        return self.row, 0, self.row, 1
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

local fake_root = {}

function fake_root:range()
    return 0, 0, 5000, 0
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

local fake_node = make_node(2405)
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
    local emitted = false
    return function()
        if
            not emitted
            and fake_node.row >= start_row
            and fake_node.row < end_row
        then
            emitted = true
            return 1, fake_node
        end
    end
end

local ts = require("typst.core.treesitter")
local old_root = ts.root
rawset(ts, "root", function()
    return fake_root
end)

local old_query_get = vim.treesitter.query.get
rawset(vim.treesitter.query, "get", function(lang, name)
    assert(lang == "typst", "large conceal spec should request Typst queries")
    assert(name == "conceal", "large conceal spec should request conceal query")
    return fake_query
end)

local config = require("typst.config")
config.setup({
    root = root,
    output_dir = typst_test_cache_path("conceal-large-range-output"),
})
local conceal = require("typst.conceal")
conceal.reset()

local bufnr = vim.api.nvim_create_buf(false, true)
local lines = {}
for index = 1, 5000 do
    lines[index] = "."
end
lines[2406] = "$"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.bo[bufnr].filetype = "typst"

local ok, err = xpcall(function()
    local matches = conceal.matches(bufnr, {
        start_row = 2400,
        end_row = 2410,
    })
    assert(#matches == 1, "large range request should return visible match")
    assert(#query_calls == 1, "large range request should query one chunk")
    local queried = query_calls[1]
    assert(
        queried.end_row - queried.start_row <= 132,
        "large range request should not scan the whole file"
    )
    assert(
        queried.start_row > 0 and queried.end_row < 5000,
        "large range request should stay near the requested window"
    )
end, debug.traceback)

vim.treesitter.query.get = old_query_get
ts.root = old_root
conceal.reset()
if not ok then
    error(err)
end

vim.cmd("qa!")
