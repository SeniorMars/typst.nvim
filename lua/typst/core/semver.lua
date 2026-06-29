local M = {}

local function string_compare(left, right)
    left = tostring(left or "")
    right = tostring(right or "")
    if left < right then
        return -1
    end
    if left > right then
        return 1
    end
    return 0
end

local function parse_prerelease(value)
    if not value then
        return nil
    end

    local identifiers = {}
    for part in value:gmatch("[^%.]+") do
        local numeric = part:match("^%d+$") ~= nil
        identifiers[#identifiers + 1] = {
            raw = part,
            numeric = numeric,
            value = numeric and tonumber(part) or part,
        }
    end
    return identifiers
end

function M.parse(version)
    if type(version) ~= "string" then
        return nil
    end

    local without_build = version:match("^([^+]+)")
    if not without_build then
        return nil
    end

    local core, prerelease =
        without_build:match("^(%d+%.%d+%.%d+)%-([0-9A-Za-z%-%.]+)$")
    core = core or without_build

    local major, minor, patch = core:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then
        return nil
    end

    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        prerelease = parse_prerelease(prerelease),
    }
end

local function compare_prerelease(left, right)
    if not left and not right then
        return 0
    end
    if not left then
        return 1
    end
    if not right then
        return -1
    end

    local limit = math.max(#left, #right)
    for index = 1, limit do
        local a = left[index]
        local b = right[index]
        if not a and not b then
            return 0
        end
        if not a then
            return -1
        end
        if not b then
            return 1
        end

        if a.numeric and b.numeric then
            if a.value < b.value then
                return -1
            end
            if a.value > b.value then
                return 1
            end
        elseif a.numeric ~= b.numeric then
            return a.numeric and -1 or 1
        else
            local compared = string_compare(a.raw, b.raw)
            if compared ~= 0 then
                return compared
            end
        end
    end

    return 0
end

function M.compare(left, right)
    local a = M.parse(left)
    local b = M.parse(right)
    if not a or not b then
        return string_compare(left, right)
    end

    for _, key in ipairs({ "major", "minor", "patch" }) do
        if a[key] < b[key] then
            return -1
        end
        if a[key] > b[key] then
            return 1
        end
    end

    return compare_prerelease(a.prerelease, b.prerelease)
end

function M.less(left, right)
    return M.compare(left, right) < 0
end

function M.newest(versions)
    local newest = versions and versions[1] or nil
    for _, version in ipairs(versions or {}) do
        if not newest or M.compare(newest, version) < 0 then
            newest = version
        end
    end
    return newest
end

function M.sort(versions)
    table.sort(versions, M.less)
    return versions
end

return M
