local M = {}

local runtime_hook_entries = {
    {
        name = "core.events",
        owner_key = "core_events",
        module = "typst.core.events",
        method = "reset",
    },
    {
        name = "preview.follow_buffer",
        owner_key = "follow_buffer",
        module = "typst.preview.follow_buffer",
        method = "reset",
    },
    {
        name = "project.lifecycle",
        owner_key = "project_lifecycle",
        module = "typst.project.lifecycle",
        method = "reset",
    },
    {
        name = "project.attachments",
        owner_key = "project_attachments",
        module = "typst.project.attachments",
        method = "reset",
    },
    {
        name = "completion",
        owner_key = "completion",
        module = "typst.completion",
        method = "reset",
    },
    {
        name = "conceal",
        owner_key = "conceal",
        module = "typst.conceal",
        method = "reset",
        loaded_only = true,
    },
    {
        name = "diagnostics",
        owner_key = "diagnostics",
        module = "typst.diagnostics",
        method = "reset",
        loaded_only = true,
    },
}

local cache_reset_entries = {
    {
        name = "match_highlight",
        module = "typst.edit.match_highlight",
        method = "reset",
        optional = true,
    },
    {
        name = "indent",
        module = "typst.edit.indent",
        method = "reset",
        optional = true,
    },
    {
        name = "bibliography_edit",
        module = "typst.bibliography.edit",
        method = "reset",
        optional = true,
    },
    {
        name = "formatting",
        module = "typst.formatting",
        method = "reset",
        optional = true,
    },
    {
        name = "completion_packages",
        module = "typst.completion.packages",
        method = "reset",
        optional = true,
    },
    {
        name = "artifacts",
        module = "typst.workflows.artifacts",
        method = "reset",
        optional = true,
        requires_pruned_projects = true,
    },
    {
        name = "package",
        module = "typst.package",
        method = "reset",
        optional = true,
    },
    {
        name = "symbol",
        module = "typst.metadata.symbol",
        method = "reset",
        optional = true,
    },
    {
        name = "metadata",
        module = "typst.metadata",
        method = "reset",
        optional = true,
    },
    {
        name = "typst_query_source_maps",
        module = "typst.preview.source_maps.typst_query",
        method = "reset",
        optional = true,
    },
    {
        name = "preview_native_server",
        module = "typst.preview.native.server",
        method = "reset",
        optional = true,
    },
    {
        name = "outputs",
        module = "typst.resources.outputs",
        method = "reset",
        requires_pruned_projects = true,
    },
    {
        name = "state",
        module = "typst.core.state",
        method = "reset_cache",
    },
    {
        name = "import_scan",
        module = "typst.project.root",
        method = "clear_import_scan_cache",
    },
}

-- Temporary reset migration debt. This table should stay empty; new overlaps
-- require a matching policy entry plus a deletion or stabilization plan.
local migration_duplicate_policy = {}

function M.runtime_hook_entries(exclude)
    local entries = {}
    for _, entry in ipairs(runtime_hook_entries) do
        if not (exclude and exclude[entry.name]) then
            entries[#entries + 1] = vim.deepcopy(entry)
        end
    end
    return entries
end

local function runtime_hook_entry(name)
    for _, entry in ipairs(runtime_hook_entries) do
        if entry.name == name then
            return { vim.deepcopy(entry) }
        end
    end
    return {}
end

function M.cache_reset_entries()
    local entries = {}
    for _, entry in ipairs(cache_reset_entries) do
        local item = vim.deepcopy(entry)
        item.owner_key = item.owner_key or item.name
        item.loaded_only = item.optional == true
        item.no_opts = true
        item.failure_message = "reset manifest cache entry failed"
        item.module_failure_message = "reset manifest cache module failed"
        entries[#entries + 1] = item
    end
    return entries
end

function M.migration_duplicate_policy()
    return vim.deepcopy(migration_duplicate_policy)
end

-- Ordered reset ownership manifest. Runtime reset executes these phases in
-- order, so the phase list is both the implementation boundary and the
-- reviewable ownership contract.
function M.phases()
    return {
        {
            name = "cancel_deferred",
            owner = "runtime.resource_manifest",
            entries = runtime_hook_entry("core.events"),
        },
        {
            name = "stop_resources",
            owner = "runtime.resource_manager",
            entries = {
                {
                    name = "live_resources",
                    owner_key = "live_resources",
                    module = "typst.runtime.resource_manager",
                    method = "stop_live_resources",
                },
            },
        },
        {
            name = "runtime_hooks",
            owner = "runtime.resource_manifest",
            entries = M.runtime_hook_entries({ ["core.events"] = true }),
        },
        {
            name = "detach_editor_state",
            owner = "runtime.setup",
            entries = {
                {
                    name = "core.ftplugin_state",
                    owner_key = "core_ftplugin_state",
                    module = "typst.core.ftplugin_state",
                    method = "reset",
                },
                {
                    name = "core.buffer",
                    owner_key = "core_buffer",
                    module = "typst.core.buffer",
                    method = "reset",
                },
            },
        },
        {
            name = "clear_project_state",
            owner = "runtime.setup",
            entries = {
                {
                    name = "project",
                    owner_key = "project",
                    module = "typst.project",
                    method = "reset",
                    skip_when_retaining_projects = true,
                },
            },
        },
        {
            name = "clear_derived_caches",
            owner = "runtime.resource_manifest",
            entries = M.cache_reset_entries(),
        },
        {
            name = "clear_globals",
            owner = "api.exports",
            entries = {
                {
                    name = "api.globals",
                    owner_key = "api_globals",
                    module = "typst.api.exports",
                    method = "reset_globals",
                    skip_when_retaining_projects = true,
                },
            },
        },
    }
end

function M.entries()
    local out = {}
    for _, phase in ipairs(M.phases()) do
        for _, entry in ipairs(phase.entries or {}) do
            out[#out + 1] = vim.tbl_extend("force", entry, {
                phase = phase.name,
                owner = phase.owner,
            })
        end
    end
    return out
end

return M
