local M = {}

local last_text_dirty_ticks = {}

local function clear_dirty_ticks_for_buffer(bufnr)
    local suffix = ":" .. tostring(bufnr)
    for key in pairs(last_text_dirty_ticks) do
        if key:sub(-#suffix) == suffix then
            last_text_dirty_ticks[key] = nil
        end
    end
end

function M.should_mark_dirty(attached, args)
    if args.event ~= "TextChanged" and args.event ~= "TextChangedI" then
        return true
    end

    local ok, changedtick = pcall(vim.api.nvim_buf_get_changedtick, args.buf)
    if not ok then
        return true
    end

    local key = ("%s:%d"):format(attached.key or "", args.buf)
    if last_text_dirty_ticks[key] == changedtick then
        return false
    end

    last_text_dirty_ticks[key] = changedtick
    return true
end

--- Forget text-change debounce state for a buffer or one project/buffer pair.
---
--- Callers that detach, re-resolve, or move a buffer to another project must
--- call this before the old project key becomes unreachable.
---@param bufnr integer Buffer whose local debounce entries should be removed.
---@param project_key? string Project key to narrow cleanup.
function M.forget(bufnr, project_key)
    if project_key then
        last_text_dirty_ticks[("%s:%d"):format(project_key, bufnr)] = nil
        return
    end
    clear_dirty_ticks_for_buffer(bufnr)
end

---@param bufnr integer Buffer whose debounce entries should be copied.
---@return table<string, integer> entries Debounce entries keyed by project/buffer pair.
function M.snapshot(bufnr)
    local suffix = ":" .. tostring(bufnr)
    local entries = {}
    for key, tick in pairs(last_text_dirty_ticks) do
        if key:sub(-#suffix) == suffix then
            entries[key] = tick
        end
    end
    return entries
end

---@param bufnr integer Buffer whose debounce entries should be restored.
---@param entries? table<string, integer> Snapshot returned by `snapshot`.
function M.restore(bufnr, entries)
    clear_dirty_ticks_for_buffer(bufnr)
    for key, tick in pairs(entries or {}) do
        last_text_dirty_ticks[key] = tick
    end
end

function M.reset()
    last_text_dirty_ticks = {}
end

---@return integer count Active debounce entries.
function M.count()
    return vim.tbl_count(last_text_dirty_ticks)
end

return M
