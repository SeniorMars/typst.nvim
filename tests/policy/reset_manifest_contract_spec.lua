local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local manifest = require("typst.runtime.resource_manifest")
local manager = require("typst.runtime.resource_manager")
local typst = require("typst")
local log = require("typst.core.log")

assert(
    package.loaded["typst.runtime.reset_manifest"] == nil,
    "reset_manifest compatibility alias should not be loaded"
)
assert(
    not pcall(require, "typst.runtime.reset_manifest"),
    "reset_manifest compatibility alias should be removed"
)
assert(
    type(manifest.execute) == "function",
    "reset manifest should execute reset"
)
assert(
    type(manager.execute_manifest) == "function",
    "resource manager should expose manifest execution"
)

local phases = manifest.phases()
assert(#phases > 0, "reset manifest should declare ordered phases")

local seen_phase = {}
local stop_owner = nil
for _, phase in ipairs(phases) do
    assert(type(phase.name) == "string" and phase.name ~= "", "phase name")
    assert(not seen_phase[phase.name], "duplicate reset phase: " .. phase.name)
    seen_phase[phase.name] = true
    if phase.name == "stop_resources" then
        stop_owner = phase.owner
    end
    assert(type(phase.owner) == "string" and phase.owner ~= "", "phase owner")
    assert(type(phase.entries) == "table", "phase entries")
end
assert(
    seen_phase.cancel_deferred,
    "manifest should expose cancel_deferred phase"
)
assert(
    seen_phase.stop_resources,
    "manifest should expose live-resource stop phase"
)
assert(
    stop_owner == "runtime.resource_manager",
    "resource manager should own reset live-resource ordering"
)

local by_name = {}
local by_owner_key = {}
local by_identity = {}
local entries_by_phase = {}
local function identity(entry)
    return entry.module .. ":" .. tostring(entry.method)
end

for _, entry in ipairs(manifest.entries()) do
    assert(type(entry.name) == "string", "entry name")
    assert(type(entry.owner_key) == "string", "entry owner_key: " .. entry.name)
    assert(type(entry.module) == "string", "entry module: " .. entry.name)
    assert(type(entry.phase) == "string", "entry phase: " .. entry.name)
    by_name[entry.name] = by_name[entry.name] or {}
    by_name[entry.name][#by_name[entry.name] + 1] = entry
    by_owner_key[entry.owner_key] = by_owner_key[entry.owner_key] or {}
    by_owner_key[entry.owner_key][#by_owner_key[entry.owner_key] + 1] = entry
    local key = identity(entry)
    by_identity[key] = by_identity[key] or {}
    by_identity[key][#by_identity[key] + 1] = entry
    entries_by_phase[entry.phase] = entries_by_phase[entry.phase] or {}
    entries_by_phase[entry.phase][#entries_by_phase[entry.phase] + 1] = entry
end

local cache_reset_required = {
    artifacts = true,
    completion_packages = true,
    formatting = true,
    import_scan = true,
    indent = true,
    metadata = true,
    outputs = true,
    package = true,
    state = true,
    symbol = true,
}
local migration_duplicates = manifest.migration_duplicate_policy()
assert(
    type(migration_duplicates) == "table",
    "reset manifest should expose migration duplicate policy"
)
assert(
    next(migration_duplicates) == nil,
    "reset manifest migration duplicate policy should be empty"
)
for name, policy in pairs(migration_duplicates) do
    assert(
        type(policy.overlaps_with) == "string" and policy.overlaps_with ~= "",
        "migration duplicate entries need an overlapping owner: " .. name
    )
    assert(
        type(policy.reason) == "string" and policy.reason ~= "",
        "migration duplicate entries need a reason: " .. name
    )
    assert(
        type(policy.remove_when) == "string" and policy.remove_when ~= "",
        "migration duplicate entries need a deletion or stabilization plan: "
            .. name
    )
end
local cache_reset_seen = {}
for _, entry in ipairs(entries_by_phase.clear_derived_caches or {}) do
    cache_reset_seen[entry.name] = true
    assert(
        type(entry.method) == "string" and entry.method ~= "",
        "manifest cache reset entry needs method: " .. entry.name
    )
end
for name in pairs(cache_reset_required) do
    assert(
        cache_reset_seen[name],
        "reset manifest missing cache reset owner: " .. name
    )
end
for name in pairs(migration_duplicates) do
    local overlaps_with = migration_duplicates[name].overlaps_with
    assert(
        cache_reset_seen[name],
        "migration duplicate policy references missing reset entry: " .. name
    )
    assert(
        by_name[overlaps_with] ~= nil,
        "migration duplicate policy references missing overlap owner: "
            .. overlaps_with
    )
end

local completion_entry = (by_name.completion or {})[1]
assert(
    completion_entry
        and completion_entry.phase == "runtime_hooks"
        and completion_entry.loaded_only ~= true,
    "completion should be the single reset owner for completion submodule caches"
)
assert(
    cache_reset_seen.completion_context == nil,
    "completion_context should not be a separate reset manifest entry"
)

local original_completion = package.loaded["typst.completion"]
local original_completion_context =
    package.loaded["typst.completion.context"]
local completion_context_resets = 0
package.loaded["typst.completion"] = nil
package.loaded["typst.completion.context"] = {
    reset = function()
        completion_context_resets = completion_context_resets + 1
        return {
            ok = true,
            reset = true,
        }
    end,
}
local completion_only_reset = manifest.reset_runtime_hooks({}, {
    ["core.events"] = true,
    ["preview.follow_buffer"] = true,
    ["project.lifecycle"] = true,
    ["project.attachments"] = true,
    conceal = true,
    diagnostics = true,
})
assert(
    completion_only_reset.completion
        and completion_only_reset.completion.ok == true,
    "completion runtime reset should run as the single completion cache owner"
)
assert(
    completion_context_resets == 1,
    "completion runtime reset should clear loaded completion.context"
)
package.loaded["typst.completion"] = original_completion
package.loaded["typst.completion.context"] = original_completion_context

local runtime_owned_reset_entries = {
    completion = true,
    conceal = true,
    diagnostics = true,
    follow_buffer = true,
    project_attachments = true,
    project_lifecycle = true,
}
for name in pairs(runtime_owned_reset_entries) do
    assert(
        not cache_reset_seen[name],
        "runtime-owned reset entry should not also be a derived-cache reset: "
            .. name
    )
end
local conceal_source = table.concat(
    vim.fn.readfile(root .. "/lua/typst/conceal/init.lua"),
    "\n"
)
assert(
    not conceal_source:find("metadata%.reset%(", 1),
    "conceal.reset should not reset metadata; reset manifest owns metadata"
)

for _, entry in ipairs(entries_by_phase.stop_resources or {}) do
    assert(
        entry.module ~= "typst.resources.drivers.editor_state",
        "stop_resources must not detach editor state"
    )
    assert(
        entry.name ~= "core.ftplugin_state" and entry.name ~= "core.buffer",
        "stop_resources must not contain editor-state cleanup entries"
    )
end

local saw_editor_detach = false
for _, entry in ipairs(entries_by_phase.detach_editor_state or {}) do
    saw_editor_detach = saw_editor_detach
        or entry.name == "core.ftplugin_state"
        or entry.name == "core.buffer"
end
assert(
    saw_editor_detach,
    "detach_editor_state phase should own editor-state cleanup"
)

for name, entries in pairs(by_name) do
    assert(#entries == 1, "duplicate reset entry name: " .. name)
end

for owner_key, entries in pairs(by_owner_key) do
    assert(#entries == 1, "duplicate reset owner key: " .. owner_key)
end

for key, entries in pairs(by_identity) do
    assert(#entries == 1, "duplicate reset identity: " .. key)
end

local original_indent = package.loaded["typst.edit.indent"]
package.loaded["typst.edit.indent"] = {
    reset = function()
        return {
            ok = false,
            reason = "synthetic_failure",
            removed = { "stale-state" },
        }
    end,
}
local structured = manifest.reset_cache_entry_results({
    retain_projects = true,
})
assert(
    structured.indent and structured.indent.ok == false,
    "manifest should preserve structured reset hook failure"
)
assert(
    structured.indent.status == "failed",
    "manifest should normalize structured reset failure status"
)
assert(
    structured.indent.reason == "synthetic_failure",
    "manifest should preserve structured reset failure reason"
)
assert(
    structured.indent.result
        and structured.indent.result.removed
        and structured.indent.result.removed[1] == "stale-state",
    "manifest should preserve structured reset hook payload"
)

package.loaded["typst.edit.indent"] = {
    reset = function()
        return false
    end,
}
local false_return = manifest.reset_cache_entry_results({
    retain_projects = true,
})
assert(
    false_return.indent
        and false_return.indent.ok == false
        and false_return.indent.status == "failed",
    "manifest should treat false reset hook returns as failures"
)

package.loaded["typst.edit.indent"] = {
    reset = function()
        error("indent reset failed")
    end,
}
log.clear()
local guarded = manifest.reset_cache_entries({ retain_projects = true })
package.loaded["typst.edit.indent"] = original_indent
assert(
    guarded.indent == false,
    "manifest should report a failing cache reset entry without aborting reset"
)
local saw_failure = false
for _, entry in ipairs(log.entries()) do
    if
        entry.message == "reset manifest cache entry failed"
        and entry.fields
        and entry.fields.name == "indent"
    then
        saw_failure = true
        break
    end
end
assert(saw_failure, "manifest should log cache reset entry failures")

local original_log = package.loaded["typst.core.log"]
local searchers = package.searchers or package.loaders
local function failing_log_searcher(name)
    if name == "typst.core.log" then
        error("synthetic log load failure")
    end
    return nil
end
package.loaded["typst.core.log"] = nil
table.insert(searchers, 1, failing_log_searcher)
package.loaded["typst.edit.indent"] = {
    reset = function()
        error("indent reset failed while log is unavailable")
    end,
}
local no_log_ok, no_log_result = pcall(manifest.reset_cache_entry_results, {
    retain_projects = true,
})
table.remove(searchers, 1)
package.loaded["typst.core.log"] = original_log
package.loaded["typst.edit.indent"] = original_indent
assert(no_log_ok, no_log_result)
assert(
    no_log_result.indent and no_log_result.indent.ok == false,
    "manifest reset failure should remain structured when log cannot load"
)

local reset = typst.reset({ force = true })
local reset_manifest = assert(
    reset and reset.reset_manifest,
    "typst.reset should return reset_manifest summary"
)
assert(
    type(reset_manifest.phases) == "table" and #reset_manifest.phases > 0,
    "reset_manifest summary should include ordered phases"
)
local saw_cancel_deferred = false
local saw_phase_status = false
for _, phase in ipairs(reset_manifest.phases) do
    assert(type(phase.ok) == "boolean", "reset phase should expose ok status")
    assert(
        phase.elapsed_ms == nil or type(phase.elapsed_ms) == "number",
        "reset phase should expose elapsed time"
    )
    assert(
        type(phase.failures) == "table",
        "reset phase should expose failures"
    )
    assert(
        type(phase.recovery) == "table",
        "reset phase should expose recovery commands"
    )
    saw_phase_status = true
    if phase.name == "cancel_deferred" then
        saw_cancel_deferred = true
        assert(
            type(phase.entries) == "table" and #phase.entries >= 1,
            "cancel_deferred phase should include core.events"
        )
    end
end
assert(saw_cancel_deferred, "reset summary should include cancel_deferred")
assert(saw_phase_status, "reset summary should include phase status")
assert(type(reset.phases) == "table", "reset should expose top-level phases")
assert(
    type(reset.phase_failures) == "table",
    "reset should expose aggregate phase failures"
)
assert(
    type(reset.recovery) == "table",
    "reset should expose aggregate recovery commands"
)

vim.cmd("qa!")
