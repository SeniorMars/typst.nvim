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
        if buffers_by_path[key] == bufnr then
            buffers_by_path[key] = nil
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
        buffers_by_path[key] = bufnr
        paths_by_buffer[bufnr][key] = true
    end
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

--- Build and return a copy of the file-path-to-buffer index.
--- Lazy-initialized and refreshed from Neovim buffers as needed.
---@return table<string, number> by_path Normalized file paths keyed to loaded buffer numbers.
function M.loaded_buffers_by_path()
    ensure_index()
    return vim.deepcopy(buffers_by_path)
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
        return by_path[path_util.path_key(path)]
            or by_path[path_util.path_key(normalized)]
    end

    local found = buffers_by_path[path_util.path_key(path)]
        or buffers_by_path[path_util.path_key(normalized)]
    if found and vim.api.nvim_buf_is_valid(found) then
        return found
    end

    build_index()
    return buffers_by_path[path_util.path_key(path)]
        or buffers_by_path[path_util.path_key(normalized)]
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
