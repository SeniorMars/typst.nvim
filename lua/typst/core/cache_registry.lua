local M = {}

local entries = {
    {
        name = "conceal",
        module = "typst.conceal",
        reset = "reset",
        optional = true,
        clear = "refresh",
        clear_args = "bufnr",
    },
    {
        name = "match_highlight",
        module = "typst.edit.match_highlight",
        reset = "reset",
        optional = true,
    },
    {
        name = "indent",
        module = "typst.edit.indent",
        reset = "reset",
        optional = true,
    },
    {
        name = "bibliography_edit",
        module = "typst.bibliography.edit",
        reset = "reset",
        optional = true,
    },
    {
        name = "formatting",
        module = "typst.formatting",
        reset = "reset",
        optional = true,
    },
    {
        name = "completion",
        module = "typst.completion",
        reset = "reset",
        optional = true,
        clear = "reset",
        reload = true,
    },
    {
        name = "completion_packages",
        module = "typst.completion.packages",
        reset = "reset",
        optional = true,
    },
    {
        name = "diagnostics",
        module = "typst.diagnostics",
        reset = "reset",
        optional = true,
    },
    {
        name = "artifacts",
        module = "typst.workflows.artifacts",
        reset = "reset",
        optional = true,
        requires_pruned_projects = true,
    },
    {
        name = "package",
        module = "typst.package",
        reset = "reset",
        optional = true,
        clear = "reset",
        reload = true,
    },
    {
        name = "symbol",
        module = "typst.metadata.symbol",
        reset = "reset",
        optional = true,
        clear = "reset",
        reload = true,
    },
    {
        name = "metadata",
        module = "typst.metadata",
        reset = "reset",
        optional = true,
        clear = "reset",
        reload = true,
    },
    {
        name = "follow_buffer",
        module = "typst.preview.follow_buffer",
        reset = "reset",
        optional = true,
    },
    {
        name = "typst_query_source_maps",
        module = "typst.preview.source_maps.typst_query",
        reset = "reset",
        optional = true,
    },
    {
        name = "path_leases",
        module = "typst.core.path_leases",
        reset = "reset",
        optional = false,
        requires_pruned_projects = true,
    },
    {
        name = "state",
        module = "typst.core.state",
        reset = "reset_cache",
        optional = false,
    },
    {
        name = "index",
        module = "typst.index",
        clear = "reset",
    },
    {
        name = "treesitter",
        module = "typst.core.treesitter",
        clear = "forget",
        clear_args = "bufnr",
    },
}

local by_name = {}
for _, entry in ipairs(entries) do
    by_name[entry.name] = entry
end

local function module_for(entry, force)
    if force then
        return require(entry.module)
    end
    return package.loaded[entry.module]
end

local function call_entry(entry, method_name, opts)
    if not entry then
        return false
    end

    local force = opts and opts.force == true
    local module = module_for(entry, force or not entry.optional)
    if type(module) ~= "table" then
        return false
    end

    local method = module[method_name]
    if type(method) ~= "function" then
        return false
    end

    local ok, err
    if entry.clear_args == "bufnr" then
        ok, err = pcall(method, opts and opts.bufnr or nil)
    else
        ok, err = pcall(method)
    end
    if not ok then
        require("typst.core.log").add("warn", "cache registry entry failed", {
            name = entry.name,
            module = entry.module,
            method = method_name,
            error = err,
        })
        return false
    end
    return true
end

local function sorted_names(names)
    table.sort(names)
    return names
end

--- Reset registered plugin-owned caches and transient state.
---@param opts? {retain_projects?:boolean}
---@return table<string, boolean> summary Reset entry names keyed by reset status.
function M.reset(opts)
    opts = opts or {}
    local summary = {}
    for _, entry in ipairs(entries) do
        if
            entry.reset
            and not (
                entry.requires_pruned_projects
                and opts.retain_projects == true
            )
        then
            summary[entry.name] = call_entry(entry, entry.reset, {
                force = not entry.optional,
            })
        end
    end
    return summary
end

--- Clear user-facing derived caches for `:TypstClearCache`.
---@param opts? {bufnr?:integer}
---@return table<string, boolean> summary Cleared entry names keyed by success.
function M.clear(opts)
    opts = opts or {}
    local summary = {}
    for _, name in ipairs({
        "metadata",
        "completion",
        "package",
        "symbol",
        "index",
        "treesitter",
        "conceal",
    }) do
        local entry = by_name[name]
        summary[name] = call_entry(entry, entry.clear, {
            force = true,
            bufnr = opts.bufnr,
        })
    end
    return summary
end

--- Refresh caches that can make project resolution or editor display stale.
---@param opts? {bufnr?:integer}
---@return table<string, boolean> summary Refreshed entry names keyed by success.
function M.reload(opts)
    opts = opts or {}
    local summary = {}
    for _, entry in ipairs(entries) do
        if entry.reload then
            summary[entry.name] = call_entry(entry, entry.reset, {
                force = true,
            })
        end
    end
    summary.conceal = call_entry(by_name.conceal, by_name.conceal.clear, {
        force = true,
        bufnr = opts.bufnr,
    })
    return summary
end

--- Return loaded/reset status for registered cache entries.
---@return table status Cache registry status summary.
function M.status()
    local status = {
        entries = {},
        loaded = {},
        unloaded = {},
    }
    for _, entry in ipairs(entries) do
        local loaded = package.loaded[entry.module] ~= nil
        local item = {
            name = entry.name,
            module = entry.module,
            loaded = loaded,
            reset = entry.reset ~= nil,
            clear = entry.clear ~= nil,
        }
        status.entries[#status.entries + 1] = item
        local bucket = loaded and status.loaded or status.unloaded
        bucket[#bucket + 1] = entry.name
    end
    sorted_names(status.loaded)
    sorted_names(status.unloaded)
    return status
end

return M
