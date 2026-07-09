local M = {}

local methods = {
    "open",
    "refresh",
    "stop",
    "toggle",
    "status",
    "capabilities",
}

---Create a small preview backend record with explicit identity fields.
---@param spec table Backend implementation fields.
---@return table backend Normalized preview backend.
function M.create(spec)
    spec = spec or {}
    local backend = {
        name = spec.name,
        kind = spec.kind,
        advanced = spec.advanced == true,
    }
    for _, method in ipairs(methods) do
        if type(spec[method]) == "function" then
            backend[method] = spec[method]
        end
    end
    return backend
end

---Return a compact backend capability snapshot.
---@param backend table? Preview backend.
---@return table capabilities Backend capabilities.
function M.capabilities(backend)
    return {
        name = backend and backend.name or nil,
        kind = backend and backend.kind or nil,
        advanced = backend and backend.advanced == true,
        open = backend and type(backend.open) == "function" or false,
        refresh = backend and type(backend.refresh) == "function" or false,
        stop = backend and type(backend.stop) == "function" or false,
        toggle = backend and type(backend.toggle) == "function" or false,
    }
end

return M
