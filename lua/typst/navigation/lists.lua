local index = require("typst.index")
local graph_dependencies = require("typst.project.graph.dependencies")
local graph_sources = require("typst.project.graph.sources")
local util = require("typst.core.util")

local M = {}

local notify_user = require("typst.core.notify").user

local function project_file_items(state)
    local buffer_paths = {}
    for bufnr in pairs(state.bufs or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local path = vim.api.nvim_buf_get_name(bufnr)
            if path ~= "" then
                buffer_paths[util.path_key(path)] = true
            end
        end
    end

    local paths = {}
    local seen = {}
    local function add(path)
        local normalized = util.normalize(path)
        local key = normalized and util.path_key(normalized) or nil
        if
            normalized
            and not seen[key]
            and vim.fn.filereadable(normalized) == 1
        then
            seen[key] = true
            paths[#paths + 1] = normalized
        end
    end

    add(state.main)
    for path in pairs(graph_sources.get(state)) do
        add(path)
    end
    for path in pairs(graph_dependencies.get(state)) do
        add(path)
    end

    table.sort(paths, function(left, right)
        local left_is_main = util.same_path(left, state.main)
        local right_is_main = util.same_path(right, state.main)
        if left_is_main and not right_is_main then
            return true
        end
        if right_is_main and not left_is_main then
            return false
        end
        return util.relpath(left, state.root) < util.relpath(right, state.root)
    end)

    return vim.tbl_map(function(path)
        local key = util.path_key(path)
        local kind = util.same_path(path, state.main) and "main"
            or buffer_paths[key] and "buffer"
            or graph_dependencies.get(state)[path] and "dependency"
            or "file"
        if kind == "file" then
            if graph_dependencies.match_path(state, path) then
                kind = "dependency"
            end
        end
        return {
            filename = path,
            lnum = 1,
            col = 1,
            text = ("[%s] %s"):format(kind, util.relpath(path, state.root)),
        }
    end, paths)
end

local function index_qf_item(state, item, label, kind)
    local source = item.source or item.definition or {}
    return {
        filename = source.path or state.main,
        lnum = source.lnum or 1,
        col = source.col or 1,
        text = ("[%s] %s"):format(kind, label),
    }
end

local function open_index_qf(title, items, map_item, opts)
    local qf_items = vim.tbl_map(map_item, items)
    vim.fn.setqflist({}, "r", {
        title = title,
        items = qf_items,
    })

    if opts.open ~= false and #qf_items > 0 then
        vim.cmd("copen")
    end

    return items
end

function M.files(state, opts, notify, log)
    opts = opts or {}
    local items = project_file_items(state)

    vim.fn.setqflist({}, "r", {
        title = ("typst.nvim files: %s"):format(
            util.relpath(state.main, state.root)
        ),
        items = items,
    })

    if opts.open ~= false and #items > 0 then
        vim.cmd("copen")
    end

    if log then
        log.add(
            "info",
            "project files listed",
            { items = #items, main = state.main }
        )
    end
    notify_user(
        notify,
        ("Files: %d item%s"):format(#items, #items == 1 and "" or "s")
    )
    return items
end

function M.labels(state, opts, notify)
    opts = opts or {}
    local collected = index.collect({ project = state }) or { labels = {} }
    local items = open_index_qf(
        ("typst.nvim labels: %s"):format(util.relpath(state.main, state.root)),
        collected.labels,
        function(item)
            return index_qf_item(state, item, item.name, "label")
        end,
        opts
    )
    notify_user(
        notify,
        ("Labels: %d item%s"):format(#items, #items == 1 and "" or "s")
    )
    return items
end

function M.citations(state, opts, notify)
    opts = opts or {}
    local collected = index.collect({ project = state }) or { citations = {} }
    local items = open_index_qf(
        ("typst.nvim citations: %s"):format(
            util.relpath(state.main, state.root)
        ),
        collected.citations,
        function(item)
            return index_qf_item(state, item, item.name, "citation")
        end,
        opts
    )
    notify_user(
        notify,
        ("Citations: %d item%s"):format(#items, #items == 1 and "" or "s")
    )
    return items
end

function M.symbols(state, opts, notify)
    opts = opts or {}
    local collected = index.collect({ project = state }) or { definitions = {} }
    local items = open_index_qf(
        ("typst.nvim symbols: %s"):format(util.relpath(state.main, state.root)),
        collected.definitions,
        function(item)
            return index_qf_item(state, item, item.name, item.kind)
        end,
        opts
    )
    notify_user(
        notify,
        ("Symbols: %d item%s"):format(#items, #items == 1 and "" or "s")
    )
    return items
end

return M
