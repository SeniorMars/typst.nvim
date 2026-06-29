local config = require("typst.config")
local diagnostics_service = require("typst.project.services.diagnostics")
local util = require("typst.core.util")

local M = {}

local quickfix_owner = nil
local quickfix_title = nil

local default_type_map = {
    [vim.diagnostic.severity.ERROR] = "E",
    [vim.diagnostic.severity.WARN] = "W",
    [vim.diagnostic.severity.INFO] = "I",
    [vim.diagnostic.severity.HINT] = "N",
}

local function diagnostic_type(diagnostic, opts)
    opts = opts or {}
    local type_map = opts.type_map or default_type_map
    return type_map[diagnostic.severity] or opts.default_type or "N"
end

local function to_qf_item(bufnr, diagnostic, opts)
    return {
        bufnr = bufnr,
        lnum = diagnostic.lnum + 1,
        col = diagnostic.col + 1,
        text = diagnostic.message,
        type = diagnostic_type(diagnostic, opts),
    }
end

local function sort_qf_items(items)
    table.sort(items, function(left, right)
        local left_name = vim.api.nvim_buf_get_name(left.bufnr)
        local right_name = vim.api.nvim_buf_get_name(right.bufnr)

        if left_name ~= right_name then
            return left_name < right_name
        end

        if left.lnum ~= right.lnum then
            return left.lnum < right.lnum
        end

        return left.col < right.col
    end)

    return items
end

local function title_for(project)
    return ("typst.nvim: %s"):format(util.relpath(project.main, project.root))
end

--- Convert diagnostics grouped by buffer into sorted quickfix items.
---@param by_buffer table<integer, table[]> Diagnostics grouped by buffer.
---@param opts? {type_map?:table<integer,string>,default_type?:string}
---@return table[] items Sorted quickfix items.
function M.items(by_buffer, opts)
    local items = {}
    for bufnr, diagnostics in pairs(by_buffer or {}) do
        for _, diagnostic in ipairs(diagnostics) do
            items[#items + 1] = to_qf_item(bufnr, diagnostic, opts)
        end
    end
    return sort_qf_items(items)
end

--- Check whether the current quickfix list belongs to a project.
---@param project table Project state whose quickfix ownership is checked.
---@return boolean owns True when typst.nvim owns quickfix for this project.
function M.owns(project)
    if quickfix_owner ~= project.key then
        return false
    end

    local ok, info = pcall(vim.fn.getqflist, { title = 1 })
    if not ok then
        return false
    end

    return info.title == quickfix_title
end

--- Replace quickfix with diagnostics grouped by buffer.
---@param project table Project state that owns the quickfix title.
---@param by_buffer table<integer, table[]> Diagnostics grouped by buffer.
---@return table[] items Quickfix items that were set.
function M.set(project, by_buffer)
    local items = M.items(by_buffer)

    quickfix_owner = project.key
    quickfix_title = title_for(project)

    vim.fn.setqflist({}, "r", {
        title = quickfix_title,
        items = items,
    })

    return items
end

--- Update quickfix when diagnostic config requests it.
---@param project table Project state that may own quickfix.
---@param by_buffer table<integer, table[]> Diagnostics grouped by buffer.
---@return table[] items Quickfix items that were set, or empty when disabled.
function M.maybe_set(project, by_buffer)
    if not config.unsafe_get().diagnostics.use_quickfix then
        return {}
    end

    return M.set(project, by_buffer)
end

--- Read currently published diagnostics for project-owned buffers.
---@param project table Project state whose diagnostic buffers are inspected.
---@param namespace integer Diagnostic namespace to read.
---@return table<integer, table[]> by_buffer Diagnostics grouped by buffer.
function M.current(project, namespace)
    local by_buffer = {}
    local diagnostic_state = diagnostics_service.get(project) or {}
    for bufnr in pairs(diagnostic_state.buffers or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local diagnostics =
                vim.diagnostic.get(bufnr, { namespace = namespace })
            if #diagnostics > 0 then
                by_buffer[bufnr] = diagnostics
            end
        end
    end

    return by_buffer
end

--- Populate and optionally open quickfix for current project diagnostics.
---@param project table Project state whose diagnostics should be opened.
---@param namespace integer Diagnostic namespace to read.
---@param opts? table Open options; `open=false` suppresses `copen`.
---@return table[] items Quickfix items that were set.
function M.open(project, namespace, opts)
    opts = opts or {}
    local items = M.set(project, M.current(project, namespace))

    if opts.open ~= false and #items > 0 then
        vim.cmd("copen")
    end

    return items
end

--- Clear typst.nvim quickfix ownership and entries.
---@param project? table Project argument kept for caller symmetry.
function M.clear(project)
    vim.fn.setqflist({}, "r", { title = "typst.nvim", items = {} })
    quickfix_owner = nil
    quickfix_title = nil
end

return M
