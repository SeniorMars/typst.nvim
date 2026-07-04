local path_util = require("typst.core.path")

local M = {}

local buffers_by_path = {}
local paths_by_buffer = {}
local initialized = false
local augroup = nil

--- Resolve Neovim's current-buffer sentinels to a concrete buffer number.
---@param bufnr? integer Buffer number; nil and 0 mean the current buffer.
---@return integer bufnr Concrete buffer number.
function M.normalize_bufnr(bufnr)
    if bufnr == nil or bufnr == 0 then
        return vim.api.nvim_get_current_buf()
    end
    return bufnr
end

local function remove_buffer(bufnr)
    for key in pairs(paths_by_buffer[bufnr] or {}) do
        local buffers = buffers_by_path[key]
        if type(buffers) == "table" then
            buffers[bufnr] = nil
            if next(buffers) == nil then
                buffers_by_path[key] = nil
            end
        end
    end
    paths_by_buffer[bufnr] = nil
end

local function add_path(bufnr, path)
    if type(path) ~= "string" or path == "" then
        return
    end

    paths_by_buffer[bufnr] = paths_by_buffer[bufnr] or {}
    for _, candidate in ipairs({ path, path_util.normalize(path) }) do
        local key = path_util.path_key(candidate)
        buffers_by_path[key] = buffers_by_path[key] or {}
        buffers_by_path[key][bufnr] = true
        paths_by_buffer[bufnr][key] = true
    end
end

local function sorted_valid_buffers(candidates)
    local out = {}
    if type(candidates) == "number" then
        candidates = { [candidates] = true }
    end
    for bufnr in pairs(candidates or {}) do
        if
            type(bufnr) == "number"
            and vim.api.nvim_buf_is_valid(bufnr)
            and vim.api.nvim_buf_is_loaded(bufnr)
        then
            out[#out + 1] = bufnr
        end
    end
    table.sort(out)
    return out
end

local function select_buffer(candidates)
    local buffers = sorted_valid_buffers(candidates)
    if #buffers == 0 then
        return nil
    end

    local current = vim.api.nvim_get_current_buf()
    for _, bufnr in ipairs(buffers) do
        if bufnr == current then
            return bufnr
        end
    end
    return buffers[#buffers]
end

local function candidates_for_key(by_path, key)
    local value = by_path and by_path[key]
    if type(value) == "number" then
        return { [value] = true }
    end
    return value
end

local function refresh_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        remove_buffer(bufnr)
        return
    end

    remove_buffer(bufnr)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        return
    end

    add_path(bufnr, vim.api.nvim_buf_get_name(bufnr))
end

local function build_index()
    buffers_by_path = {}
    paths_by_buffer = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        refresh_buffer(bufnr)
    end
end

local function ensure_index()
    if initialized then
        return
    end

    initialized = true
    build_index()
    augroup = vim.api.nvim_create_augroup("typst_nvim_buffer_index", {
        clear = true,
    })
    vim.api.nvim_create_autocmd({ "BufAdd", "BufEnter", "BufFilePost" }, {
        group = augroup,
        callback = function(args)
            refresh_buffer(args.buf)
        end,
    })
    vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
        group = augroup,
        callback = function(args)
            remove_buffer(args.buf)
        end,
    })
end

--- Build and return a compatibility file-path-to-selected-buffer map.
--- Lazy-initialized and refreshed from Neovim buffers as needed.
---@return table<string, number> by_path Normalized file paths keyed to selected loaded buffer numbers.
function M.loaded_buffers_by_path()
    ensure_index()
    local selected = {}
    for key, candidates in pairs(buffers_by_path) do
        local bufnr = select_buffer(candidates)
        if bufnr then
            selected[key] = bufnr
        end
    end
    return selected
end

--- Return all loaded buffers currently indexed for a path.
---@param path? string File path to look up.
---@param by_path? table<string, integer|table<integer, boolean>> Optional path map.
---@return integer[] bufnrs Valid loaded buffers, sorted by buffer number.
function M.loaded_buffers_for_path(path, by_path)
    ensure_index()
    local normalized = path and path_util.normalize(path) or nil
    if not normalized then
        return {}
    end

    by_path = by_path or buffers_by_path
    local candidates = candidates_for_key(by_path, path_util.path_key(path))
        or candidates_for_key(by_path, path_util.path_key(normalized))
    local buffers = sorted_valid_buffers(candidates)
    if #buffers > 0 or by_path ~= buffers_by_path then
        return buffers
    end

    build_index()
    candidates = candidates_for_key(buffers_by_path, path_util.path_key(path))
        or candidates_for_key(buffers_by_path, path_util.path_key(normalized))
    return sorted_valid_buffers(candidates)
end

--- Return the loaded buffer for a path, if any.
---@param path? string File path to look up.
---@param by_path? table<string, integer> Optional precomputed path-to-buffer map.
---@return integer? bufnr Loaded buffer number.
function M.loaded_buffer_for_path(path, by_path)
    ensure_index()
    local normalized = path and path_util.normalize(path) or nil
    if not normalized then
        return nil
    end

    if by_path then
        return select_buffer(
            candidates_for_key(by_path, path_util.path_key(path))
                or candidates_for_key(by_path, path_util.path_key(normalized))
        )
    end

    local found = select_buffer(
        buffers_by_path[path_util.path_key(path)]
            or buffers_by_path[path_util.path_key(normalized)]
    )
    if found then
        return found
    end

    build_index()
    return select_buffer(
        buffers_by_path[path_util.path_key(path)]
            or buffers_by_path[path_util.path_key(normalized)]
    )
end

--- Switch to an existing loaded buffer for a path or edit the path.
---@param path? string File path to open.
---@return integer? bufnr Current buffer after opening, or nil for an empty path.
function M.edit_existing_or_path(path)
    if not path or path == "" then
        return nil
    end

    local bufnr = M.loaded_buffer_for_path(path)
    if bufnr then
        vim.api.nvim_set_current_buf(bufnr)
        return bufnr
    end

    vim.cmd.edit(vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
end

--- Read a buffer variable without raising when it is absent.
---@param bufnr integer Buffer to inspect.
---@param name string Buffer variable name without the `b:` prefix.
---@return any value Variable value, or nil when absent.
function M.get_buf_var(bufnr, name)
    local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
    if ok then
        return value
    end
    return nil
end

--- Set a buffer variable.
---@param bufnr integer Buffer to mutate.
---@param name string Buffer variable name without the `b:` prefix.
---@param value any Value to store.
function M.set_buf_var(bufnr, name, value)
    vim.api.nvim_buf_set_var(bufnr, name, value)
end

--- Delete a buffer variable without raising when it is absent.
---@param bufnr integer Buffer to mutate.
---@param name string Buffer variable name without the `b:` prefix.
function M.del_buf_var(bufnr, name)
    pcall(vim.api.nvim_buf_del_var, bufnr, name)
end

--- Reset buffer path caches and autocmds.
function M.reset()
    if augroup then
        pcall(vim.api.nvim_del_augroup_by_id, augroup)
    end
    augroup = nil
    initialized = false
    buffers_by_path = {}
    paths_by_buffer = {}
end

return M
