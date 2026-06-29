local M = {}

function M.lower(value)
    return type(value) == "string" and value:lower() or ""
end

function M.starts_with(value, prefix)
    value = type(value) == "string" and value or ""
    prefix = type(prefix) == "string" and prefix or ""
    return value:sub(1, #prefix) == prefix
end

function M.prefix(candidate, base)
    if base == "" or base == nil then
        return true
    end

    return M.starts_with(M.lower(candidate), M.lower(base))
end

function M.any_prefix(candidates, base)
    for _, candidate in ipairs(candidates or {}) do
        if M.prefix(candidate, base) then
            return true
        end
    end
    return false
end

return M
