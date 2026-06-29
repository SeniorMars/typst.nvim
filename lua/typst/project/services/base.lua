local M = {}

local scalar_types = {
    boolean = true,
    number = true,
    string = true,
}

function M.copy_value(value, depth, seen)
    local kind = type(value)
    if value == nil or scalar_types[kind] then
        return value
    end
    if kind ~= "table" or depth <= 0 then
        return nil
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local out = {}
    seen[value] = out
    for key, child in pairs(value) do
        if scalar_types[type(key)] then
            local copied = M.copy_value(child, depth - 1, seen)
            if copied ~= nil then
                out[key] = copied
            end
        end
    end
    return out
end

function M.services(project)
    if type(project) ~= "table" then
        return nil
    end
    if type(project.services) ~= "table" then
        project.services = {}
    end
    return project.services
end

function M.service(project, name)
    local services = M.services(project)
    if not services then
        return nil
    end
    if type(services[name]) ~= "table" then
        services[name] = {}
    end
    return services[name]
end

function M.update(project, name, fields)
    local service = M.service(project, name)
    if not service then
        return nil
    end

    for _, key in ipairs((fields and (fields.clear or fields._clear)) or {}) do
        service[key] = nil
    end
    for key, value in pairs(fields or {}) do
        if key ~= "clear" and key ~= "_clear" then
            service[key] = value
        end
    end
    return service
end

return M
