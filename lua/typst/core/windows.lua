local buffer = require("typst.core.buffer")

local M = {}

local function normalize_winid(winid)
    if type(winid) ~= "number" then
        winid = tonumber(winid)
    end
    if not winid then
        return nil
    end
    return winid
end

local function valid_window(winid)
    winid = normalize_winid(winid)
    if not winid then
        return false
    end
    local ok, valid = pcall(vim.api.nvim_win_is_valid, winid)
    return ok and valid == true
end

function M.has_buffer(winid, bufnr)
    winid = normalize_winid(winid)
    if not valid_window(winid) then
        return false
    end
    local ok, current_bufnr = pcall(vim.api.nvim_win_get_buf, winid)
    return ok and current_bufnr == bufnr
end

---Find a visible window for a buffer.
---@param bufnr? integer Buffer to locate; defaults like other buffer APIs.
---@param opts? {winid?:integer,current_first?:boolean,strict?:boolean}
---@return integer? winid Matching window id, if any.
function M.for_buffer(bufnr, opts)
    opts = opts or {}
    bufnr = buffer.normalize_bufnr(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    if opts.winid ~= nil then
        local requested = normalize_winid(opts.winid)
        if M.has_buffer(requested, bufnr) then
            return requested
        end
        if opts.strict ~= false then
            return nil
        end
    end

    if opts.current_first ~= false then
        local current = vim.api.nvim_get_current_win()
        if M.has_buffer(current, bufnr) then
            return current
        end
    end

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if M.has_buffer(winid, bufnr) then
            return winid
        end
    end
end

---Return every visible window displaying a buffer.
---@param bufnr? integer Buffer to locate; defaults like other buffer APIs.
---@return integer[] winids Matching windows.
function M.all_for_buffer(bufnr)
    bufnr = buffer.normalize_bufnr(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    local out = {}
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if M.has_buffer(winid, bufnr) then
            out[#out + 1] = winid
        end
    end
    return out
end

return M
