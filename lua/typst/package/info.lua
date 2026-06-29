local actions = require("typst.package.actions")
local cache = require("typst.package.cache")
local context = require("typst.package.context")
local log = require("typst.core.log")
local open_helper = require("typst.core.open")
local semver = require("typst.core.semver")

local M = {}

-- Public package resource facade. Resolve explicit results/queries first so
-- commands and context-menu actions can reuse previous lookup work; cursor
-- inference is the fallback for interactive use.

local notify = require("typst.core.notify").default

local function as_opts(value)
    if type(value) == "string" then
        return { query = value }
    end

    return value or {}
end

local function resolve_context(opts)
    local ctx = context.resolve(opts)
    if not ctx or not ctx.query then
        return nil
    end

    return ctx
end

function M.resolve(opts)
    opts = as_opts(opts)
    if opts.result then
        return opts.result
    end

    if opts.query then
        return cache.lookup(opts.query)
    end

    local ctx = resolve_context(opts)
    if not ctx then
        return nil
    end

    local result = nil
    if ctx.kind == "package_member" then
        result = cache.lookup_member(ctx)
    elseif ctx.kind == "package" or cache.looks_like(ctx.query) then
        result = cache.lookup(ctx.query)
    end

    if result then
        result.context = result.context or ctx
    end
    return result
end

function M.info(opts)
    opts = as_opts(opts)
    local result = M.resolve(opts)
    if not result then
        notify("No Typst package resources found", vim.log.levels.WARN)
        return nil
    end

    log.add("info", "opened Typst package resources", {
        id = result.id,
        provider = result.provider,
    })

    if opts.open == false then
        return result
    end

    actions.open(result, opts)
    return result
end

local function source_result(opts)
    opts = as_opts(opts)
    return M.resolve(vim.tbl_extend("force", opts, { open = false }))
end

local function open_path(path, opts)
    if opts.open == false then
        return path
    end

    if path and vim.fn.filereadable(path) == 1 then
        local opened = open_helper.file(path, opts)
        return opened and path or nil
    end
end

function M.source(opts)
    opts = as_opts(opts)
    local result = source_result(opts)
    local source = result and result.source
    local path = source and source.path
    if not path then
        notify(
            "No local Typst package source is available",
            vim.log.levels.WARN
        )
        return nil
    end

    local opened = open_path(path, opts)
    return opts.open == false and source or opened
end

function M.readme(opts)
    opts = as_opts(opts)
    local result = source_result(opts)
    local path = result and result.package and result.package.readme
    if not path then
        notify(
            "No cached Typst package README is available",
            vim.log.levels.WARN
        )
        return nil
    end

    local opened = open_path(path, opts)
    if opts.open == false then
        return {
            path = path,
            text = result.readme,
            package = result.package,
        }
    end
    return opened
end

function M.open(opts)
    opts = as_opts(opts)
    local result = source_result(opts)
    local url = opts.url
        or (
            result
            and result.links
            and (
                result.links.reference
                or result.links.homepage
                or result.links.repository
            )
        )
    if not url then
        notify("No online Typst package URL found", vim.log.levels.WARN)
        return nil
    end

    if opts.open == false then
        return url
    end

    local opened, err = open_helper.url(url)
    if opened then
        return url
    end
    if err then
        notify(("Open manually: %s (%s)"):format(url, err), vim.log.levels.WARN)
        return nil, err
    end

    notify(("Open manually: %s"):format(url), vim.log.levels.WARN)
    return url
end

function M.complete(arglead)
    local needle = (arglead or ""):lower()
    local items = {}
    for _, record in ipairs(cache.cached_packages({ prefix = needle })) do
        local candidates = {
            record.spec,
            ("@%s/%s"):format(record.namespace, record.name),
            ("%s/%s"):format(record.namespace, record.name),
            record.name,
        }
        for _, candidate in ipairs(candidates) do
            if needle == "" or candidate:lower():find(needle, 1, true) == 1 then
                items[#items + 1] = record.spec
                break
            end
        end
    end
    table.sort(items, function(left, right)
        local a = cache.parse_spec(left)
        local b = cache.parse_spec(right)
        if not a or not b or a.namespace ~= b.namespace or a.name ~= b.name then
            return left < right
        end
        return semver.less(a.version, b.version)
    end)
    return items
end

function M.reset()
    cache.reset()
    actions.reset()
end

return M
