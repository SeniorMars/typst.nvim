local api_spec = require("typst.api.spec")

local M = {}

M.version = 1

local event_aliases = {
    TypstProjectAttach = { "TypstEventProjectAttach" },
    TypstBufferDetach = {
        "TypstEventBufferDetach",
        "TypstProjectDetach",
        "TypstEventProjectDetach",
    },
    TypstProjectDetach = {
        "TypstEventProjectDetach",
        "TypstEventBufferDetach",
    },
    TypstProjectPruned = { "TypstEventProjectPruned" },
    TypstCompileStarted = { "TypstEventCompileStarted", "TypstEventCompiling" },
    TypstCompileSuccess = { "TypstEventCompileSuccess" },
    TypstCompileFailed = { "TypstEventCompileFailed" },
    TypstCompileStopped = { "TypstEventCompileStopped" },
    TypstCompilerForceCleared = { "TypstEventCompilerForceCleared" },
    TypstPreviewOpened = { "TypstEventPreviewStarted" },
    TypstPreviewForwarded = { "TypstEventPreviewForwarded" },
    TypstPreviewInverse = { "TypstEventPreviewInverse" },
    TypstPreviewStopped = { "TypstEventPreviewStopped" },
    TypstViewInverse = { "TypstEventViewInverse" },
    TypstArtifactCreated = { "TypstEventArtifactCreated" },
    TypstArtifactsCleaned = { "TypstEventArtifactsCleaned" },
    TypstRenderCreated = { "TypstEventRenderCreated" },
    TypstTocCreated = { "TypstEventTocCreated" },
    TypstTocActivated = { "TypstEventTocActivated" },
}

local global_events = {
    "TypstEventInitPre",
    "TypstEventInitPost",
    "TypstEventConfigChanged",
    "TypstEventQuit",
}

local common_project_payload = {
    "key",
    "root",
    "main",
    "output",
    "status",
    "provider",
    "profile",
    "cwd",
    "command",
    "viewer_backend",
    "viewer_command",
    "viewer_cwd",
    "preview_backend",
    "preview_command",
    "preview_cwd",
    "preview_mode",
    "preview_active",
}

local attach_payload = {
    "event_kind",
    "bufnr",
    "buffer",
    "resolution_pending",
    "reason",
    "remaining_buffers",
    "finalization_ok",
    "finalization_error",
}

local buffer_lifecycle_payload = {
    "event_kind",
    "bufnr",
    "buffer",
    "reason",
    "remaining_buffers",
    "project_pruned",
}

local preview_started_payload = {
    "backend",
    "mode",
    "output",
    "export",
    "url",
    "follow_buffer",
    "previous_project",
}

local preview_stopped_payload = {
    "backend",
    "mode",
    "command",
    "cwd",
    "reason",
    "lifecycle",
    "forced",
}

local source_sync_payload = {
    "backend",
    "path",
    "line",
    "column",
    "source_sync",
    "output",
}

local compile_payload = vim.list_extend(vim.deepcopy(common_project_payload), {
    "event_kind",
    "compiler_event",
    "watch",
    "cycle",
    "generation",
    "watch_generation",
    "cycle_generation",
    "watch_status",
    "last_cycle_status",
    "output_wait_ms",
    "output_wait_attempts",
    "code",
    "reason",
    "message",
    "deps_path",
    "stale",
    "stopped",
    "idle",
    "forced",
})
local setup_payload =
    { "provider", "did_setup", "first_setup", "reconfigure", "setup_once" }
local config_changed_payload = {
    "provider",
    "did_setup",
    "first_setup",
    "reconfigure",
    "reapply",
}

local event_payloads = {
    TypstEventInitPre = vim.deepcopy(setup_payload),
    TypstEventInitPost = vim.deepcopy(setup_payload),
    TypstEventConfigChanged = vim.deepcopy(config_changed_payload),
    TypstEventQuit = { "provider", "projects" },
    TypstEventProjectAttach = vim.list_extend(
        vim.deepcopy(common_project_payload),
        attach_payload
    ),
    TypstEventBufferDetach = vim.list_extend(
        vim.deepcopy(common_project_payload),
        buffer_lifecycle_payload
    ),
    TypstEventProjectDetach = vim.list_extend(
        vim.deepcopy(common_project_payload),
        buffer_lifecycle_payload
    ),
    TypstEventProjectPruned = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "event_kind",
            "reason",
            "remaining_buffers",
            "project_pruned",
        }
    ),
    TypstEventCompileStarted = vim.deepcopy(compile_payload),
    TypstEventCompiling = vim.deepcopy(compile_payload),
    TypstEventCompileSuccess = vim.deepcopy(compile_payload),
    TypstEventCompileFailed = vim.deepcopy(compile_payload),
    TypstEventCompileStopped = vim.deepcopy(compile_payload),
    TypstEventCompilerForceCleared = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "key_display",
            "output",
            "released_lease",
            "stopped",
            "forced",
            "discarded",
            "reason",
            "message",
            "lease_owner",
        }
    ),
    TypstEventPreviewStarted = vim.list_extend(
        vim.deepcopy(common_project_payload),
        preview_started_payload
    ),
    TypstEventPreviewStopped = vim.list_extend(
        vim.deepcopy(common_project_payload),
        preview_stopped_payload
    ),
    TypstEventPreviewForwarded = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "backend",
            "line",
            "column",
            "source_sync",
            "command",
        }
    ),
    TypstEventPreviewInverse = vim.list_extend(
        vim.list_extend(
            vim.deepcopy(common_project_payload),
            source_sync_payload
        ),
        {
            "page",
            "x",
            "y",
        }
    ),
    TypstEventViewInverse = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "viewer_provider",
            "path",
            "line",
            "column",
        }
    ),
    TypstEventArtifactCreated = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "id",
            "path",
            "canonical_path",
            "format",
            "signature",
            "freshness",
            "reason",
            "producer",
            "preview_export",
        }
    ),
    TypstEventArtifactsCleaned = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "deleted",
            "failed",
            "skipped",
            "producer",
        }
    ),
    TypstEventRenderCreated = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "path",
            "kind",
            "source",
            "format",
            "page",
        }
    ),
    TypstEventTocCreated = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "items",
        }
    ),
    TypstEventTocActivated = vim.list_extend(
        vim.deepcopy(common_project_payload),
        {
            "items",
        }
    ),
}

local function payload_for(event)
    return vim.deepcopy(event_payloads[event] or {})
end

event_payloads.TypstProjectAttach = payload_for("TypstEventProjectAttach")
event_payloads.TypstBufferDetach = payload_for("TypstEventBufferDetach")
event_payloads.TypstProjectDetach = payload_for("TypstEventProjectDetach")
event_payloads.TypstProjectPruned = payload_for("TypstEventProjectPruned")
event_payloads.TypstCompileStarted = payload_for("TypstEventCompileStarted")
event_payloads.TypstCompileSuccess = payload_for("TypstEventCompileSuccess")
event_payloads.TypstCompileFailed = payload_for("TypstEventCompileFailed")
event_payloads.TypstCompileStopped = payload_for("TypstEventCompileStopped")
event_payloads.TypstCompilerForceCleared =
    payload_for("TypstEventCompilerForceCleared")
event_payloads.TypstPreviewOpened = payload_for("TypstEventPreviewStarted")
event_payloads.TypstPreviewForwarded = payload_for("TypstEventPreviewForwarded")
event_payloads.TypstPreviewInverse = payload_for("TypstEventPreviewInverse")
event_payloads.TypstPreviewStopped = payload_for("TypstEventPreviewStopped")
event_payloads.TypstViewInverse = payload_for("TypstEventViewInverse")
event_payloads.TypstArtifactCreated = payload_for("TypstEventArtifactCreated")
event_payloads.TypstArtifactsCleaned = payload_for("TypstEventArtifactsCleaned")
event_payloads.TypstRenderCreated = payload_for("TypstEventRenderCreated")
event_payloads.TypstTocCreated = payload_for("TypstEventTocCreated")
event_payloads.TypstTocActivated = payload_for("TypstEventTocActivated")
event_payloads.TypstDiagnosticsPublished =
    vim.list_extend(vim.deepcopy(common_project_payload), {
        "diagnostics_count",
        "diagnostic_buffers",
        "bufnr",
    })
event_payloads.TypstDiagnosticsCleared =
    payload_for("TypstDiagnosticsPublished")
event_payloads.TypstOutputCleaned =
    vim.list_extend(vim.deepcopy(common_project_payload), {
        "output",
        "output_deleted",
        "temporary",
        "temporary_skipped",
        "preview_artifacts",
        "preview_artifacts_skipped",
        "preview_artifacts_failed",
    })
event_payloads.TypstViewOpened =
    vim.list_extend(vim.deepcopy(common_project_payload), {
        "viewer_provider",
        "viewer_backend",
        "viewer_command",
        "viewer_cwd",
    })
event_payloads.TypstViewForwarded =
    vim.list_extend(vim.deepcopy(common_project_payload), {
        "viewer_provider",
        "output",
        "line",
        "column",
        "viewer_backend",
    })
local compatibility_events = {
    "TypstArtifactCreated",
    "TypstArtifactsCleaned",
    "TypstBufferDetach",
    "TypstCompileFailed",
    "TypstCompileStarted",
    "TypstCompileStopped",
    "TypstCompileSuccess",
    "TypstCompilerForceCleared",
    "TypstDiagnosticsCleared",
    "TypstDiagnosticsPublished",
    "TypstOutputCleaned",
    "TypstPreviewForwarded",
    "TypstPreviewInverse",
    "TypstPreviewOpened",
    "TypstPreviewStopped",
    "TypstProjectAttach",
    "TypstProjectDetach",
    "TypstProjectPruned",
    "TypstRenderCreated",
    "TypstTocActivated",
    "TypstTocCreated",
    "TypstViewForwarded",
    "TypstViewInverse",
    "TypstViewOpened",
}

local function sorted(values)
    local out = {}
    local seen = {}
    for _, value in ipairs(values or {}) do
        if not seen[value] then
            seen[value] = true
            out[#out + 1] = value
        end
    end
    table.sort(out)
    return out
end

local function sorted_keys(tbl)
    local out = vim.tbl_keys(tbl or {})
    table.sort(out)
    return out
end

--- Return compatibility aliases for primary internal event names.
---@return table<string,string[]> aliases Event aliases keyed by primary name.
function M.event_aliases()
    return vim.deepcopy(event_aliases)
end

--- Return documented public `TypstEvent*` event names.
---@return string[] events Public event names.
function M.events()
    local seen = {}
    for _, event in ipairs(global_events) do
        seen[event] = true
    end
    for primary, aliases in pairs(event_aliases) do
        if primary:find("^TypstEvent") then
            seen[primary] = true
        end
        for _, alias in ipairs(aliases) do
            if alias:find("^TypstEvent") then
                seen[alias] = true
            end
        end
    end
    return sorted_keys(seen)
end

--- Return documented payload fields for public events.
---@return table<string,string[]> payloads Event payload fields by public name.
function M.event_payloads()
    local out = {}
    for event, fields in pairs(event_payloads) do
        out[event] = sorted(fields)
    end
    return out
end

--- Return compatibility-only and legacy public event names.
---@return string[] events Compatibility event names.
function M.compatibility_events()
    return sorted(compatibility_events)
end

--- Return a versioned public API/event contract snapshot.
---@return table contract Contract metadata suitable for docs and tests.
function M.snapshot()
    return {
        version = M.version,
        api_version = 1,
        stable_root_functions = sorted(api_spec.stable_root_functions),
        stable_namespaces = sorted_keys(api_spec.stable_namespaces),
        stable_runtime_symbols = sorted(api_spec.stable_runtime_symbols),
        namespace_tiers = vim.deepcopy(api_spec.namespace_tiers or {}),
        internal_module_prefixes = sorted(api_spec.internal_module_prefixes),
        events = M.events(),
        compatibility_events = M.compatibility_events(),
        event_aliases = M.event_aliases(),
        event_payloads = M.event_payloads(),
    }
end

return M
