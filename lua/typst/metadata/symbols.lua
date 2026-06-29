local symbol_artifacts = require("typst.metadata.symbol_artifacts")

local M = {}

local function starts_with(value, prefix)
    return type(value) == "string" and value:sub(1, #prefix) == prefix
end

local function lower_bound(values, target)
    local low = 1
    local high = #values + 1
    while low < high do
        local mid = math.floor((low + high) / 2)
        if values[mid] < target then
            low = mid + 1
        else
            high = mid
        end
    end
    return low
end

function M.map(version, artifact_name, kind, prefix)
    local artifact = symbol_artifacts.load(version, artifact_name)
    local cache_key = ("map:%s:%s"):format(kind, prefix)
    if artifact[cache_key] then
        return artifact[cache_key]
    end

    local map = {}
    for _, name in ipairs(artifact.names) do
        map[name] = symbol_artifacts.record(artifact, name, kind, prefix)
    end

    artifact[cache_key] = map
    return map
end

function M.record(version, artifact_name, name, kind, prefix)
    return symbol_artifacts.record(
        symbol_artifacts.load(version, artifact_name),
        name,
        kind,
        prefix
    )
end

function M.variant_names(version, artifact_name, name)
    if type(name) ~= "string" then
        return {}
    end
    local artifact = symbol_artifacts.load(version, artifact_name)
    name = symbol_artifacts.canonical_name(artifact, name)
    if not name then
        return {}
    end
    local result = {}
    for _, variant in ipairs(symbol_artifacts.variant_records(artifact, name)) do
        result[#result + 1] = variant.canonical
    end
    return result
end

function M.variant_records(version, artifact_name, name)
    if type(name) ~= "string" then
        return {}
    end
    local artifact = symbol_artifacts.load(version, artifact_name)
    name = symbol_artifacts.canonical_name(artifact, name)
    if not name then
        return {}
    end
    return vim.deepcopy(symbol_artifacts.variant_records(artifact, name))
end

function M.deprecation(version, artifact_name, name)
    return symbol_artifacts.load(version, artifact_name).deprecated[name]
end

function M.names(version, artifact_name)
    return vim.deepcopy(symbol_artifacts.load(version, artifact_name).names)
end

function M.iter(version, artifact_name, kind, prefix)
    local artifact = symbol_artifacts.load(version, artifact_name)
    local index = 0
    return function()
        index = index + 1
        local name = artifact.names[index]
        if not name then
            return nil
        end
        return name, symbol_artifacts.record(artifact, name, kind, prefix)
    end
end

function M.complete(version, artifact_name, prefix, limit)
    prefix = prefix or ""
    limit = limit or math.huge
    local artifact = symbol_artifacts.load(version, artifact_name)
    local result = {}
    local index = prefix == "" and 1 or lower_bound(artifact.names, prefix)
    while index <= #artifact.names and #result < limit do
        local name = artifact.names[index]
        if prefix ~= "" and not starts_with(name, prefix) then
            break
        end
        result[#result + 1] = name
        index = index + 1
    end
    return result
end

function M.reset()
    symbol_artifacts.reset()
end

return M
