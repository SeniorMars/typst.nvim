local M = {}

local entries = {
    {
        name = "project_attachments",
        module = "typst.project.attachments",
        forget = "forget",
        forget_args = "bufnr",
        optional = true,
    },
    {
        name = "conceal",
        module = "typst.conceal",
        optional = true,
        clear = "refresh",
        clear_args = "bufnr",
        forget = "forget",
        forget_args = "bufnr",
        detach = "detach",
        detach_args = "bufnr",
        forget_window = "_forget_window",
        forget_window_args = "winid",
    },
    {
        name = "match_highlight",
        module = "typst.edit.match_highlight",
        detach = "detach",
        detach_args = "bufnr",
        optional = true,
    },
    {
        name = "indent",
        module = "typst.edit.indent",
        forget = "forget",
        forget_args = "bufnr",
        optional = true,
    },
    {
        name = "bibliography_edit",
        module = "typst.bibliography.edit",
        forget = "forget",
        forget_args = "bufnr",
        optional = true,
    },
    {
        name = "formatting",
        module = "typst.formatting",
        forget = "forget",
        forget_args = "bufnr",
        optional = true,
    },
    {
        name = "syntax",
        module = "typst.syntax",
        detach = "clear",
        detach_args = "bufnr",
        optional = true,
    },
    {
        name = "completion",
        module = "typst.completion",
        optional = true,
        clear = "reset",
        reload = "reset",
    },
    {
        name = "completion_context",
        module = "typst.completion.context",
        forget = "clear_cache",
        forget_args = "bufnr",
        optional = true,
    },
    {
        name = "package",
        module = "typst.package",
        optional = true,
        clear = "reset",
        reload = "reset",
    },
    {
        name = "symbol",
        module = "typst.metadata.symbol",
        optional = true,
        clear = "reset",
        reload = "reset",
    },
    {
        name = "metadata",
        module = "typst.metadata",
        optional = true,
        clear = "reset",
        reload = "reset",
    },
    {
        name = "index",
        module = "typst.index",
        clear = "reset",
    },
    {
        name = "import_scan",
        module = "typst.project.root",
        clear = "clear_import_scan_cache",
    },
    {
        name = "treesitter",
        module = "typst.core.treesitter",
        clear = "forget",
        clear_args = "bufnr",
        forget = "forget",
        forget_args = "bufnr",
    },
}

local by_name = {}
for _, entry in ipairs(entries) do
    by_name[entry.name] = entry
end

local function rebuild_index()
    by_name = {}
    for _, entry in ipairs(entries) do
        by_name[entry.name] = entry
    end
end

local function module_for(entry, force)
    if force then
        return require(entry.module)
    end
    return package.loaded[entry.module]
end

local function call_entry(entry, method_name, opts, operation)
    if not entry then
        return false
    end
    if type(method_name) ~= "string" then
        return false
    end

    local force = opts and opts.force == true
    local operation_name = operation or method_name
    local lifecycle_operation = operation_name == "forget"
        or operation_name == "detach"
        or operation_name == "forget_window"
    local module = module_for(
        entry,
        force or (not lifecycle_operation and not entry.optional)
    )
    if type(module) ~= "table" then
        return false
    end

    local method = module[method_name]
    if type(method) ~= "function" then
        return false
    end

    local ok, err
    local arg_kind = entry[(operation or method_name) .. "_args"]
    if arg_kind == "bufnr" then
        ok, err = pcall(method, opts and opts.bufnr or nil)
    elseif arg_kind == "winid" then
        ok, err = pcall(method, opts and opts.winid or nil)
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
        "import_scan",
        "treesitter",
        "conceal",
    }) do
        local entry = by_name[name]
        summary[name] = call_entry(entry, entry.clear, {
            force = true,
            bufnr = opts.bufnr,
        }, "clear")
    end
    return summary
end

--- Forget buffer-local transient state for a buffer.
---@param bufnr integer Buffer whose registry entries should forget local state.
---@return table<string, boolean> summary Entry names keyed by cleanup status.
function M.forget_buffer(bufnr)
    local summary = {}
    for _, entry in ipairs(entries) do
        if entry.forget then
            summary[entry.name] = call_entry(entry, entry.forget, {
                bufnr = bufnr,
            }, "forget")
        end
    end
    return summary
end

--- Detach buffer-local UI state from a still-valid buffer.
---@param bufnr integer Buffer receiving detach cleanup.
---@return table<string, boolean> summary Entry names keyed by cleanup status.
function M.detach_buffer(bufnr)
    local summary = {}
    for _, entry in ipairs(entries) do
        if entry.detach then
            summary[entry.name] = call_entry(entry, entry.detach, {
                bufnr = bufnr,
            }, "detach")
        end
    end
    return summary
end

--- Forget window-local transient state for a closed or closing window.
---@param winid integer|string Window id as passed by WinClosed.
---@return table<string, boolean> summary Entry names keyed by cleanup status.
function M.forget_window(winid)
    local summary = {}
    for _, entry in ipairs(entries) do
        if entry.forget_window then
            summary[entry.name] = call_entry(entry, entry.forget_window, {
                winid = winid,
            }, "forget_window")
        end
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
            summary[entry.name] = call_entry(entry, entry.reload, {
                force = true,
            }, "reload")
        end
    end
    for _, name in ipairs({ "index", "import_scan", "treesitter" }) do
        local entry = by_name[name]
        summary[name] = call_entry(entry, entry.clear, {
            force = true,
            bufnr = opts.bufnr,
        }, "clear")
    end
    summary.conceal = call_entry(by_name.conceal, by_name.conceal.clear, {
        force = true,
        bufnr = opts.bufnr,
    }, "clear")
    return summary
end

---Register a cache entry in tests.
---@param entry table Cache registry entry.
function M._register_for_tests(entry)
    entries[#entries + 1] = entry
    rebuild_index()
end

---Remove a test cache entry by name.
---@param name string Cache registry entry name.
function M._unregister_for_tests(name)
    for index = #entries, 1, -1 do
        if entries[index].name == name then
            table.remove(entries, index)
        end
    end
    rebuild_index()
end

---Return a copy of registered cache entries for policy tests.
---@return table[] entries_snapshot Cache registry entry metadata.
function M._entries_for_tests()
    return vim.deepcopy(entries)
end

---Return a copy of registered cache entries for reset manifest/catalog views.
---@return table[] entries_snapshot Cache registry entry metadata.
function M.entries()
    return vim.deepcopy(entries)
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
            owner_key = entry.owner_key or entry.name,
            module = entry.module,
            optional = entry.optional == true,
            loaded = loaded,
            clear = entry.clear ~= nil,
            clear_method = entry.clear,
            forget = entry.forget ~= nil,
            forget_method = entry.forget,
            detach = entry.detach ~= nil,
            detach_method = entry.detach,
            forget_window = entry.forget_window ~= nil,
            forget_window_method = entry.forget_window,
        }
        status.entries[#status.entries + 1] = item
        local bucket = loaded and status.loaded or status.unloaded
        bucket[#bucket + 1] = entry.name
    end
    sorted_names(status.loaded)
    sorted_names(status.unloaded)
    return status
end

--- Return aggregate cache registry metrics for reports and health checks.
---@return TypstCacheRegistryStats stats Cache registry counts and capability totals.
function M.stats()
    local status = M.status()
    local stats = {
        total = #status.entries,
        loaded = #status.loaded,
        unloaded = #status.unloaded,
        clear = 0,
        reload = 0,
        forget = 0,
        detach = 0,
        forget_window = 0,
        optional = 0,
        required = 0,
        entries = status.entries,
    }

    for _, entry in ipairs(entries) do
        if entry.clear then
            stats.clear = stats.clear + 1
        end
        if entry.reload then
            stats.reload = stats.reload + 1
        end
        if entry.forget then
            stats.forget = stats.forget + 1
        end
        if entry.detach then
            stats.detach = stats.detach + 1
        end
        if entry.forget_window then
            stats.forget_window = stats.forget_window + 1
        end
        if entry.optional then
            stats.optional = stats.optional + 1
        else
            stats.required = stats.required + 1
        end
    end

    return stats
end

return M
