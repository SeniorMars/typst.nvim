local config = require("typst.config")
local index = require("typst.index")
local project_context = require("typst.project.context")

local M = {}

M.normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.project_for(opts)
    opts = opts or {}
    if type(opts.project) == "table" then
        return opts.project
    end

    local bufnr = M.normalize_bufnr(opts.bufnr)
    return project_context.resolve({ bufnr = bufnr }, { create = true })
end

function M.package_key(spec)
    if type(spec) ~= "string" then
        return nil
    end

    return spec:match("^(@[^:]+)") or spec
end

local function extension_name(key, spec)
    local name = spec.name or key:match("/([^/%s:]+)$") or key:gsub("^@", "")
    return (name:gsub("[^%w_]+", "_"))
end

local function copy_members(spec)
    local members = {}
    for _, member in ipairs(spec.members or {}) do
        members[#members + 1] = member
    end
    return members
end

local function configured_extension(spec)
    local syntax = config.unsafe_get().syntax or {}
    local packages = syntax.packages or {}
    return packages[spec] or packages[M.package_key(spec)]
end

local function normalize_extension(import)
    local syntax = config.unsafe_get().syntax or {}
    local spec = configured_extension(import.spec)
    if not spec or spec.enabled == false then
        return nil
    end

    local key = M.package_key(import.spec)
    local name = extension_name(key, spec)
    return {
        name = name,
        package = import.spec,
        package_key = key,
        capture = spec.capture or ("@typst.package." .. name),
        highlight_group = spec.highlight_group
            or syntax.package_highlight_group
            or "TypstPackageSpecial",
        priority = spec.priority or syntax.package_highlight_priority or 115,
        members = copy_members(spec),
        source = import.source,
    }
end

function M.list(opts)
    opts = opts or {}
    local syntax = config.unsafe_get().syntax or {}
    if not syntax.package_extensions then
        return {}
    end

    local project = M.project_for(opts)
    if not project then
        return {}
    end

    local collected = opts.collected or index.collect({ project = project })
    if not collected then
        return {}
    end

    local extensions = {}
    local seen = {}
    for _, import in ipairs(collected.imports or {}) do
        local extension = normalize_extension(import)
        if extension and not seen[extension.package] then
            seen[extension.package] = true
            extensions[#extensions + 1] = extension
        end
    end

    table.sort(extensions, function(a, b)
        return a.package < b.package
    end)
    return extensions
end

return M
