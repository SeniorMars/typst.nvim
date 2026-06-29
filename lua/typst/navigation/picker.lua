local backends = require("typst.navigation.picker_backends")
local items = require("typst.navigation.picker_items")
local util = require("typst.core.util")

local M = {}

function M.kind_names()
    return items.kind_names()
end

function M.items(opts)
    return items.items(opts)
end

function M.open_item(item, opts)
    opts = opts or {}
    if not item then
        return nil
    end

    if type(opts.action) == "function" then
        return opts.action(item, opts)
    end

    local source = item.source or {}
    if type(source.path) ~= "string" or source.path == "" then
        return nil
    end

    util.edit_existing_or_path(source.path)
    pcall(vim.api.nvim_win_set_cursor, 0, {
        math.max(source.lnum or 1, 1),
        math.max((source.col or 1) - 1, 0),
    })
    return item
end

function M.open(opts)
    opts = opts or {}
    local picker_items = opts.items or M.items(opts)
    return backends.open(picker_items, opts, {
        open_item = M.open_item,
    })
end

return M
