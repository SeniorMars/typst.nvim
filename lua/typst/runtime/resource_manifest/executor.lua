local entries = require("typst.runtime.resource_manifest.entries")

local M = {}

local function hrtime()
    local uv = vim.uv or vim.loop
    return uv and uv.hrtime() or 0
end

local function elapsed_ms(started)
    local finished = hrtime()
    if started == 0 or finished == 0 then
        return nil
    end
    return (finished - started) / 1000000
end

local function module_for(entry)
    if entry.loaded_only then
        return package.loaded[entry.module]
    end
    return require(entry.module)
end

local function log_reset_failure(message, entry, err)
    local ok_log, log = pcall(require, "typst.core.log")
    if ok_log and type(log) == "table" and type(log.add) == "function" then
        pcall(log.add, "warn", message, {
            name = entry.name,
            module = entry.module,
            method = entry.method,
            error = err,
        })
    end
end

local function project_command_key(project_key)
    if not project_key then
        return nil
    end
    local ok, store = pcall(require, "typst.project.store")
    if ok and type(store.encode_key) == "function" then
        local encoded_ok, encoded = pcall(store.encode_key, project_key)
        if encoded_ok and encoded then
            return encoded
        end
    end
    return tostring(project_key)
end

local function recovery_for_reason(reason, failure)
    local project_key = failure and failure.project_key
    local encoded_key = project_command_key(project_key)
    if
        reason == "compiler_stop_failed"
        or reason == "compiler_stop_unconfirmed"
        or reason == "stop_unconfirmed"
    then
        return encoded_key and (":TypstCompilerForceClear! " .. encoded_key)
            or ":TypstCompilerForceClear!"
    end
    if
        reason == "preview_stop_error"
        or reason == "preview_stop_pending"
        or reason == "preview_stop_failed"
        or reason == "preview_stop_declined"
    then
        return ":TypstPreviewStop"
    end
    if
        reason == "project_operation_cancel_incomplete"
        or reason == "global_operation_cancel_incomplete"
        or reason == "global_operations_remain"
        or reason == "operation_cancel_incomplete"
    then
        return ":TypstReset!"
    end
    if
        reason == "output_reset_failed"
        or reason == "output_lock_release_failed"
    then
        return ":TypstLocks"
    end
    if reason == "retained_projects" then
        return ":TypstStatus"
    end
    if
        reason == "driver_exception"
        or reason == "resource_manager_reset_error"
    then
        return ":TypstStatus"
    end
    return nil
end

local function entry_failed(result)
    if result == false then
        return true
    end
    if type(result) ~= "table" then
        return false
    end
    if result.ok == false then
        return true
    end
    if
        result.status == "error"
        or result.status == "missing_method"
        or result.status == "failed"
    then
        return true
    end
    return false
end

local function normalize_entry_return(returned, started)
    local elapsed = elapsed_ms(started)
    if returned == false then
        return {
            ok = false,
            status = "failed",
            reason = "failed",
            result = returned,
            elapsed_ms = elapsed,
        }
    end

    if type(returned) == "table" then
        local ok = returned.ok ~= false
            and returned.status ~= "error"
            and returned.status ~= "missing_method"
            and returned.status ~= "failed"
        local normalized = vim.deepcopy(returned)
        normalized.ok = ok
        normalized.status = returned.status or (ok and "reset" or "failed")
        normalized.result = returned
        normalized.elapsed_ms = elapsed
        return normalized
    end

    return {
        ok = true,
        status = "reset",
        result = returned,
        elapsed_ms = elapsed,
    }
end

local function call_entry(entry, opts)
    local started = hrtime()
    local ok, module_or_err = pcall(module_for, entry)
    if not ok or type(module_or_err) ~= "table" then
        if entry.loaded_only and module_or_err == nil then
            return {
                ok = true,
                status = "skipped_unloaded",
                elapsed_ms = elapsed_ms(started),
            }
        end
        if not entry.loaded_only then
            log_reset_failure(
                entry.module_failure_message or "reset manifest module failed",
                entry,
                module_or_err
            )
        end
        return {
            ok = false,
            status = "error",
            error = tostring(module_or_err),
            elapsed_ms = elapsed_ms(started),
        }
    end

    local method_name = entry.method
    local method = module_or_err[method_name]
    if type(method) ~= "function" then
        return {
            ok = false,
            status = "missing_method",
            elapsed_ms = elapsed_ms(started),
        }
    end

    local called, returned
    if entry.no_opts then
        called, returned = pcall(method)
    else
        called, returned = pcall(method, opts)
    end
    if called then
        return normalize_entry_return(returned, started)
    end

    log_reset_failure(
        entry.failure_message or "reset manifest entry failed",
        entry,
        returned
    )
    return {
        ok = false,
        status = "error",
        error = tostring(returned),
        elapsed_ms = elapsed_ms(started),
    }
end

local function run_entries(entry_list, opts)
    local summary = {}
    for _, entry in ipairs(entry_list or {}) do
        summary[entry.name] = call_entry(entry, opts)
    end
    return summary
end

---Reset runtime hook entries through the manifest-owned executor.
---@param opts? table Reset controls.
---@param exclude? table<string, boolean> Runtime hook names to skip.
---@return table<string, table> summary Hook names keyed by reset status.
function M.reset_runtime_hooks(opts, exclude)
    return run_entries(entries.runtime_hook_entries(exclude), opts or {})
end

local function run_stop_resources(opts)
    local ok, result = xpcall(function()
        return require("typst.runtime.resource_manager").stop_live_resources(
            opts
        )
    end, debug.traceback)
    if ok and type(result) == "table" then
        return result
    end
    return {
        ok = false,
        projects = 0,
        failed = {
            {
                reason = "resource_manager_reset_error",
                result = result,
            },
        },
    }
end

local function stop_resource_failures(result)
    local failures = {}
    for _, failure in ipairs((type(result) == "table" and result.failed) or {}) do
        local reason = failure.reason or "failed"
        failures[#failures + 1] = {
            entry = "live_resources",
            reason = reason,
            main = failure.main,
            project_key = failure.project_key,
            result = failure.result,
            retained = failure.retained,
            recovery = recovery_for_reason(reason, failure),
        }
    end
    return failures
end

local function phase_failures(phase, result)
    local failures = {}
    if phase.name == "stop_resources" then
        return stop_resource_failures(result)
    end

    local phase_results = type(result) == "table" and result or {}
    for _, entry in ipairs(phase.entries or {}) do
        local entry_result = phase_results[entry.name]
        if entry_failed(entry_result) then
            local reason = type(entry_result) == "table"
                    and (entry_result.reason or entry_result.status)
                or "failed"
            failures[#failures + 1] = {
                entry = entry.name,
                owner_key = entry.owner_key or entry.name,
                module = entry.module,
                method = entry.method,
                reason = reason,
                result = entry_result,
                recovery = recovery_for_reason(reason, {
                    entry = entry.name,
                }),
            }
        end
    end
    return failures
end

local function phase_ok(phase, result, failures)
    if phase.name == "stop_resources" then
        return type(result) == "table" and result.ok ~= false
    end
    return #failures == 0
end

local function phase_recovery(failures)
    local seen = {}
    local recovery = {}
    for _, failure in ipairs(failures or {}) do
        local command = failure.recovery
        if command and not seen[command] then
            seen[command] = true
            recovery[#recovery + 1] = command
        end
    end
    return recovery
end

local function build_phase_detail(phase, result, started)
    local failures = phase_failures(phase, result)
    return {
        name = phase.name,
        owner = phase.owner,
        ok = phase_ok(phase, result, failures),
        elapsed_ms = elapsed_ms(started),
        failures = failures,
        recovery = phase_recovery(failures),
    }
end

---Reset manifest cache entries through the manifest-owned executor.
---@param opts? {retain_projects?:boolean} Reset controls.
---@return table<string, table> summary Cache names keyed by structured status.
function M.reset_cache_entry_results(opts)
    opts = opts or {}
    local summary = {}
    for _, entry in ipairs(entries.cache_reset_entries()) do
        if entry.requires_pruned_projects and opts.retain_projects == true then
            summary[entry.name] = {
                ok = true,
                status = "skipped",
                reason = "retained_projects",
            }
        else
            summary[entry.name] = call_entry(entry, opts)
        end
    end
    return summary
end

---Reset manifest cache entries through the manifest-owned executor.
---@param opts? {retain_projects?:boolean} Reset controls.
---@return table<string, boolean> summary Cache names keyed by reset success.
function M.reset_cache_entries(opts)
    opts = opts or {}
    local summary = {}
    local detailed = M.reset_cache_entry_results(opts)
    for _, entry in ipairs(entries.cache_reset_entries()) do
        local result = detailed[entry.name]
        if result and result.reason ~= "retained_projects" then
            summary[entry.name] = result.ok ~= false
                and result.status ~= "skipped_unloaded"
        end
    end
    return summary
end

local function run_globals(retain_projects)
    if retain_projects then
        return {
            skipped = true,
            reason = "retained_projects",
        }
    end
    return require("typst.api.exports").reset_globals()
end

---Execute the ordered runtime reset manifest.
---
---This is the reset source of truth. Compatibility helpers such as
---`core.cache_registry` owns clear/reload/buffer cleanup; reset entries live
---here so runtime reset has one owner.
---@param opts? table Reset controls.
---@return table results Phase results keyed by manifest phase name plus `retain_projects`.
function M.execute(opts)
    opts = opts or {}
    local results = {
        _phase_details = {},
        _phase_order = {},
    }
    local retain_projects = false

    for _, phase in ipairs(entries.phases()) do
        local phase_started = hrtime()
        local phase_result = nil
        if phase.name == "stop_resources" then
            results.stop_resources = run_stop_resources(opts)
            phase_result = results.stop_resources
            retain_projects = type(results.stop_resources) == "table"
                and results.stop_resources.retain_projects == true
                and opts.force ~= true
            results.retain_projects = retain_projects
        elseif phase.name == "cancel_deferred" then
            results.cancel_deferred = run_entries(phase.entries, opts)
            phase_result = results.cancel_deferred
        elseif phase.name == "runtime_hooks" then
            results.runtime_hooks =
                M.reset_runtime_hooks(opts, { ["core.events"] = true })
            phase_result = results.runtime_hooks
        elseif phase.name == "detach_editor_state" then
            results.detach_editor_state = run_entries(phase.entries, opts)
            phase_result = results.detach_editor_state
        elseif phase.name == "clear_project_state" then
            if retain_projects then
                results.clear_project_state = {
                    project = {
                        ok = true,
                        status = "skipped",
                        reason = "retained_projects",
                    },
                }
            else
                results.clear_project_state = run_entries(phase.entries, opts)
            end
            phase_result = results.clear_project_state
        elseif phase.name == "clear_derived_caches" then
            results.clear_derived_caches = M.reset_cache_entry_results({
                retain_projects = retain_projects,
            })
            phase_result = results.clear_derived_caches
        elseif phase.name == "clear_globals" then
            results.clear_globals = run_globals(retain_projects)
            phase_result = results.clear_globals
        else
            results[phase.name] = {
                ok = false,
                status = "unknown_phase",
            }
            phase_result = results[phase.name]
        end
        local detail = build_phase_detail(phase, phase_result, phase_started)
        results._phase_details[phase.name] = detail
        results._phase_order[#results._phase_order + 1] = detail
    end

    results.retain_projects = retain_projects
    return results
end

local function entry_result(entry, phase_name, results)
    results = results or {}
    local phase_results = results[phase_name]
    if type(phase_results) ~= "table" then
        return nil
    end

    if phase_name == "stop_resources" then
        return {
            ok = phase_results.ok ~= false,
            status = phase_results.ok == false and "failed" or "reset",
        }
    end

    if phase_name == "clear_globals" and entry.name == "api.globals" then
        return phase_results
    end

    return phase_results[entry.name]
end

---Build a structured reset phase summary from the ordered manifest.
---@param opts? {retain_projects?:boolean}
---@param results? table Phase result payloads keyed by manifest phase.
---@return table summary Ordered reset phases with entry-level status.
function M.summary(opts, results)
    opts = opts or {}
    results = results or {}
    local phases = {}
    for _, phase in ipairs(entries.phases()) do
        local detail = results._phase_details
                and results._phase_details[phase.name]
            or nil
        local phase_summary = {
            name = phase.name,
            owner = phase.owner,
            ok = detail and detail.ok ~= false or nil,
            elapsed_ms = detail and detail.elapsed_ms or nil,
            failures = detail and vim.deepcopy(detail.failures or {}) or {},
            recovery = detail and vim.deepcopy(detail.recovery or {}) or {},
            entries = {},
        }
        for _, entry in ipairs(phase.entries or {}) do
            local skipped = entry.skip_when_retaining_projects == true
                and opts.retain_projects == true
            local item = {
                name = entry.name,
                owner_key = entry.owner_key or entry.name,
                module = entry.module,
                method = entry.method,
                skipped = skipped,
                reason = skipped and "retained_projects" or nil,
            }
            if not skipped then
                item.result = entry_result(entry, phase.name, results)
                if type(item.result) == "table" then
                    item.ok = item.result.ok ~= false
                        and item.result.status ~= "error"
                        and item.result.status ~= "missing_method"
                        and item.result.status ~= "failed"
                    item.status = item.result.status
                    item.elapsed_ms = item.result.elapsed_ms
                    item.reason = item.result.reason or item.reason
                elseif item.result ~= nil then
                    item.ok = item.result ~= false
                    item.status = item.ok and "reset" or "failed"
                end
            end
            phase_summary.entries[#phase_summary.entries + 1] = item
        end
        phases[#phases + 1] = phase_summary
    end
    return { phases = phases }
end

return M
