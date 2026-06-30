local config = require("typst.config")
local diagnostics_service = require("typst.project.services.diagnostics")
local util = require("typst.core.util")

local M = {}

local quickfix_owner = nil
local quickfix_title = nil
local loclist_owners = {}

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

local function current_title()
    local ok, info = pcall(vim.fn.getqflist, { title = 1 })
    if not ok then
        return nil
    end
    return info.title
end

local function normalize_list_kind(kind)
    kind = kind or ((config.unsafe_get().diagnostics or {}).list or "quickfix")
    if kind == "location" then
        kind = "loclist"
    end
    return kind == "loclist" and "loclist" or "quickfix"
end

local function valid_winid(winid)
    if type(winid) ~= "number" then
        return false
    end
    local ok, valid = pcall(vim.api.nvim_win_is_valid, winid)
    return ok and valid
end

local function target_winid(opts)
    local winid = opts and opts.winid
    if valid_winid(winid) then
        return winid
    end
    return vim.api.nvim_get_current_win()
end

local function current_loclist_title(winid)
    local ok, info = pcall(vim.fn.getloclist, winid, { title = 1 })
    if not ok then
        return nil
    end
    return info.title
end

local function owns_quickfix(project)
    return quickfix_owner == project.key and current_title() == quickfix_title
end

local function owns_loclist(project, winid)
    local owner = loclist_owners[winid]
    return owner
        and owner.key == project.key
        and current_loclist_title(winid) == owner.title
end

local function owns_any_loclist(project)
    for winid in pairs(loclist_owners) do
        if valid_winid(winid) and owns_loclist(project, winid) then
            return true
        end
    end
    return false
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
    if type(project) ~= "table" then
        return false
    end

    return owns_quickfix(project) or owns_any_loclist(project)
end

--- Replace quickfix with diagnostics grouped by buffer.
---@param project table Project state that owns the quickfix title.
---@param by_buffer table<integer, table[]> Diagnostics grouped by buffer.
---@param opts? {list?:string,winid?:integer}
---@return table[] items Quickfix items that were set.
function M.set(project, by_buffer, opts)
    opts = opts or {}
    local items = M.items(by_buffer)
    local title = title_for(project)

    if normalize_list_kind(opts.list) == "loclist" then
        local winid = target_winid(opts)
        loclist_owners[winid] = {
            key = project.key,
            title = title,
        }
        vim.fn.setloclist(winid, {}, "r", {
            title = title,
            items = items,
        })
        return items
    end

    quickfix_owner = project.key
    quickfix_title = title

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
    local diagnostics_config = config.unsafe_get().diagnostics
    if not diagnostics_config.use_quickfix then
        return {}
    end

    return M.set(project, by_buffer, { list = diagnostics_config.list })
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
    local list_kind = normalize_list_kind(opts.list)
    local winid = list_kind == "loclist" and target_winid(opts) or nil
    if list_kind == "loclist" and not valid_winid(winid) then
        return {}
    end
    if winid then
        opts = vim.tbl_extend("force", opts, { winid = winid })
    end

    local items = M.set(project, M.current(project, namespace), opts)

    if opts.open ~= false and #items > 0 then
        if list_kind == "loclist" then
            vim.api.nvim_win_call(winid, function()
                vim.cmd("lopen")
            end)
        else
            vim.cmd("copen")
        end
    end

    return items
end

local function clear_quickfix(project, force)
    if not force and project and not owns_quickfix(project) then
        return false
    end

    vim.fn.setqflist({}, "r", { title = "typst.nvim", items = {} })
    quickfix_owner = nil
    quickfix_title = nil
    return true
end

local function clear_loclist(project, opts)
    opts = opts or {}
    local winid = target_winid(opts)
    if not opts.force and project and not owns_loclist(project, winid) then
        return false
    end

    local ok = pcall(vim.fn.setloclist, winid, {}, "r", {
        title = "typst.nvim",
        items = {},
    })
    loclist_owners[winid] = nil
    return ok
end

local function clear_owned_loclists(project, force)
    local cleared = false
    for winid, owner in pairs(vim.deepcopy(loclist_owners)) do
        local valid = valid_winid(winid)
        local title_matches = valid
            and current_loclist_title(winid) == owner.title
        local project_matches = not project or owner.key == project.key
        if
            valid
            and (force or project_matches)
            and (force or title_matches)
        then
            local ok = pcall(vim.fn.setloclist, winid, {}, "r", {
                title = "typst.nvim",
                items = {},
            })
            loclist_owners[winid] = nil
            cleared = ok or cleared
        elseif not valid then
            loclist_owners[winid] = nil
        elseif project_matches and not title_matches then
            -- The user replaced the location list. Preserve it, but stop
            -- treating the window as typst.nvim-owned.
            loclist_owners[winid] = nil
        end
    end
    return cleared
end

--- Clear typst.nvim quickfix ownership and entries.
---@param project? table Project state whose ownership should be respected.
---@param opts? {force?:boolean,list?:string,winid?:integer} Clear controls; `force=true` ignores ownership.
---@return boolean cleared True when a diagnostics list was replaced.
function M.clear(project, opts)
    opts = opts or {}
    if opts.list then
        if normalize_list_kind(opts.list) == "loclist" then
            return clear_loclist(project, opts)
        end
        return clear_quickfix(project, opts.force == true)
    end

    local cleared = clear_quickfix(project, opts.force == true)
    return clear_owned_loclists(project, opts.force == true) or cleared
end

--- Reset quickfix state during global plugin reset.
--- Clears the list only when the visible quickfix still matches typst.nvim ownership.
---@return boolean cleared True when the quickfix list was replaced.
function M.reset()
    local should_clear = quickfix_owner ~= nil
        and quickfix_title ~= nil
        and current_title() == quickfix_title
    quickfix_owner = nil
    quickfix_title = nil
    local cleared = false
    if should_clear then
        cleared = M.clear(nil, { force = true, list = "quickfix" })
    end
    return clear_owned_loclists(nil, false) or cleared
end

function M._loclist_owner_count_for_tests()
    return vim.tbl_count(loclist_owners)
end

return M
