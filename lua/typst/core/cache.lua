local M = {}
local uv = vim.uv or vim.loop

function M.now_ms()
    return uv.now()
end

---@param ttl_ms number|nil
---@param now_ms number|nil
---@return number|nil expires_at
function M.expires_at(ttl_ms, now_ms)
    ttl_ms = tonumber(ttl_ms)
    if not ttl_ms or ttl_ms <= 0 then
        return nil
    end
    return (now_ms or M.now_ms()) + ttl_ms
end

---@param entry table|nil
---@param opts? {signature?:string,ttl_ms?:number,now_ms?:number}
---@return boolean fresh
function M.is_fresh(entry, opts)
    opts = opts or {}
    if type(entry) ~= "table" then
        return false
    end
    if opts.signature ~= nil and entry.signature ~= opts.signature then
        return false
    end

    local ttl_ms = tonumber(opts.ttl_ms)
    if ttl_ms == 0 then
        return true
    end
    if ttl_ms and ttl_ms > 0 then
        return (entry.expires_at or 0) > (opts.now_ms or M.now_ms())
    end
    return true
end

---@param fields table|nil
---@param opts? {signature?:string,ttl_ms?:number,now_ms?:number}
---@return table entry
function M.entry(fields, opts)
    opts = opts or {}
    local entry = vim.tbl_extend("force", {}, fields or {})
    if opts.signature ~= nil then
        entry.signature = opts.signature
    end
    entry.expires_at = M.expires_at(opts.ttl_ms, opts.now_ms)
    return entry
end

return M
