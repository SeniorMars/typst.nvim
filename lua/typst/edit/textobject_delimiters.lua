local matchparen = require("typst.edit.matchparen")
local ts = require("typst.edit.treesitter")
local util = require("typst.edit.textobject_util")

local M = {}

local delimiter_closers = {
    ["("] = ")",
    ["["] = "]",
    ["{"] = "}",
}

local function before_or_at(row_a, col_a, row_b, col_b)
    return row_a < row_b or (row_a == row_b and col_a <= col_b)
end

local function pair_contains(pair, row, col)
    return before_or_at(pair.open.row, pair.open.col, row, col)
        and before_or_at(row, col, pair.close.row, pair.close.end_col - 1)
end

local function delimiter_pair_size(pair)
    return (pair.close.row - pair.open.row) * 100000
        + (pair.close.end_col - pair.open.col)
end

local function delimiter_pairs(tokens)
    local pairs = {}
    local stack = {}
    local math_open = nil

    for _, token in ipairs(tokens) do
        if token.kind == "math" then
            if math_open then
                pairs[#pairs + 1] = {
                    kind = "math",
                    open = math_open,
                    close = token,
                }
                math_open = nil
            else
                math_open = token
            end
        elseif token.kind == "open" then
            stack[#stack + 1] = token
        elseif token.kind == "close" then
            for index = #stack, 1, -1 do
                local opener = stack[index]
                if delimiter_closers[opener.char] == token.char then
                    table.remove(stack, index)
                    pairs[#pairs + 1] = {
                        kind = "delimiter",
                        open = opener,
                        close = token,
                    }
                    break
                end
            end
        end
    end

    return pairs
end

function M.find_pair(bufnr, pos)
    local row, col = util.cursor_position(pos, bufnr)
    if not row or not col then
        return nil
    end
    local best = nil
    for _, pair in ipairs(delimiter_pairs(matchparen.collect_tokens(bufnr))) do
        if pair_contains(pair, row, col) then
            if
                not best
                or delimiter_pair_size(pair) < delimiter_pair_size(best)
            then
                best = pair
            end
        end
    end

    return best
end

function M.range(bufnr, pair, part)
    if part == "outer" then
        return {
            start_row = pair.open.row,
            start_col = pair.open.col,
            end_row = pair.close.row,
            end_col = pair.close.end_col,
        }
    end

    return ts.trim_whitespace(bufnr, {
        start_row = pair.open.row,
        start_col = pair.open.end_col,
        end_row = pair.close.row,
        end_col = pair.close.col,
    })
end

return M
