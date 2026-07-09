local context = require("typst.runtime.resource_context")

local M = {}

local last_reset_summary = nil

local function hrtime()
    local uv = vim.uv or vim.loop
    return uv and uv.hrtime() or 0
end

local function project_store()
    return require("typst.project.store")
end

local function resource_session()
    return require("typst.resources.session")
end

local function resource_manifest()
    return require("typst.runtime.resource_manifest")
end

local function safe_log_add(level, message, fields)
    local ok, log = pcall(require, "typst.core.log")
    if ok and type(log) == "table" and type(log.add) == "function" then
        pcall(log.add, level, message, fields)
    end
end

local function safe_log_clear()
    local ok, log = pcall(require, "typst.core.log")
    if ok and type(log) == "table" and type(log.clear) == "function" then
        pcall(log.clear)
    end
end

local function project_command_key(project)
    local project_key = type(project) == "table" and project.key or nil
    if not project_key then
        return nil
    end
    local ok, encoded = pcall(project_store().encode_key, project_key)
    if ok and encoded then
        return encoded
    end
    return tostring(project_key)
end

local function recovery_for_blocker(blocker, project)
    local kind = blocker and blocker.kind or nil
    local encoded_key = project_command_key(project)
    if
        kind == "compiler_stop_unconfirmed"
        or kind == "compiler_stopping"
        or kind == "compiler_output_lease"
    then
        return encoded_key and (":TypstCompilerForceClear! " .. encoded_key)
            or ":TypstCompilerForceClear!"
    end
    if kind == "compiler_process" or kind == "compiler_watcher" then
        return ":TypstStop"
    end
    if
        kind == "preview_active"
        or kind == "preview_opening"
        or kind == "preview_stopping"
        or kind == "preview_stop_unconfirmed"
    then
        return ":TypstPreviewStop"
    end
    if kind == "preview_failed" then
        return ":TypstPreviewStatus!"
    end
    if kind == "operation_active" or kind == "operation_retained" then
        return ":TypstReset!"
    end
    if kind == "output_lease" then
        return ":TypstStatus"
    end
    if kind == "output_lock_release_failed" then
        return ":TypstLocks"
    end
    if
        kind == "global_operation_active"
        or kind == "global_operation_retained"
    then
        return ":TypstReset!"
    end
    if kind == "resolution_pending" then
        return ":TypstStatus"
    end
    if kind == "main_confidence_low" then
        return ":TypstSetMain"
    end
    if kind == "index_fs_watch_polling" or kind == "index_fs_watch_partial" then
        return ":checkhealth typst"
    end
    return nil
end

local function enrich_blocker(blocker, project)
    local item = vim.deepcopy(blocker or {})
    if not item.command then
        item.command = recovery_for_blocker(item, project)
    end
    if not item.recovery and item.command then
        item.recovery = item.command
    end
    return item
end

local function enrich_project_snapshot(snapshot, project)
    local blockers = {}
    for _, blocker in ipairs(snapshot.blockers or {}) do
        blockers[#blockers + 1] = enrich_blocker(blocker, project)
    end
    snapshot.blockers = blockers
    snapshot.blocker_count = #blockers
    return snapshot
end

local function enrich_global_snapshot(snapshot)
    local blockers = {}
    for _, blocker in ipairs(snapshot.blockers or {}) do
        blockers[#blockers + 1] = enrich_blocker(blocker, nil)
    end
    snapshot.blockers = blockers
    snapshot.blocker_count = #blockers
    return snapshot
end

local function global_snapshot()
    local session = resource_session().global_snapshot()
    session.deferred = require("typst.core.events").deferred_snapshot()
    session.reset = context.state()
    local ok, locks = pcall(function()
        return require("typst.resources.outputs").locks({
            include_current = true,
        })
    end)
    session.output_locks = ok and locks
        or {
            ok = false,
            error = tostring(locks),
        }
    return enrich_global_snapshot(session)
end

local function project_snapshot(project)
    local snapshot = enrich_project_snapshot(
        resource_session().snapshot(project) or {},
        project
    )
    snapshot.epoch = context.epoch()
    snapshot.resetting = context.in_reset()
    snapshot.project_key = project.key
    snapshot.root = project.root
    snapshot.main = project.main
    snapshot.global = global_snapshot()
    return snapshot
end

local function full_snapshot()
    local projects = {}
    local blockers = {}
    for key, project in pairs(project_store().all()) do
        local snapshot = enrich_project_snapshot(
            resource_session().snapshot(project) or {},
            project
        )
        snapshot.project_key = project.key
        snapshot.root = project.root
        snapshot.main = project.main
        projects[key] = snapshot
        for _, blocker in ipairs(snapshot.blockers or {}) do
            local item = vim.deepcopy(blocker)
            item.scope = item.scope or "project"
            item.project_key = item.project_key or project.key
            item.main = item.main or project.main
            blockers[#blockers + 1] = item
        end
    end

    local global = global_snapshot()
    for _, blocker in ipairs(global.blockers or {}) do
        local item = vim.deepcopy(blocker)
        item.scope = item.scope or "global"
        blockers[#blockers + 1] = item
    end

    return {
        epoch = context.epoch(),
        resetting = context.in_reset(),
        projects = projects,
        global = global,
        blockers = blockers,
        blocker_count = #blockers,
    }
end

local function force_warning_failure(failure)
    if type(failure) ~= "table" then
        return false
    end
    if failure.retained == false then
        return true
    end
    if failure.reason == "global_operations_remain" then
        local result = failure.result
        return type(result) == "table"
            and (result.abandoned or 0) > 0
            and (result.active_after or 0) == 0
            and (result.retained_after or 0) == 0
    end
    return false
end

local function attach_reset_metadata(reset_result, reset_results, ctx, opts)
    if type(reset_result) ~= "table" then
        return reset_result
    end

    local retain_projects = opts.force ~= true
        and reset_results.retain_projects == true
    reset_result.force = opts.force == true
    reset_result.epoch = ctx.epoch
    reset_result.reason = opts.reason or "reset"
    reset_result.started_at = ctx.started_at
    reset_result.finished_at = hrtime()
    reset_result.retained_projects = retain_projects
    reset_result.runtime_hooks = vim.tbl_extend(
        "force",
        reset_results.cancel_deferred or {},
        reset_results.runtime_hooks or {}
    )
    reset_result.globals = reset_results.clear_globals
    local manifest_summary = resource_manifest().summary({
        retain_projects = retain_projects,
    }, reset_results)
    reset_result.reset_manifest = manifest_summary
    reset_result.phases = vim.deepcopy(manifest_summary.phases or {})
    local phase_failures = {}
    local recovery = {}
    local seen_recovery = {}
    for _, phase in ipairs(reset_result.phases or {}) do
        if phase.ok == false then
            reset_result.ok = false
        end
        for _, failure in ipairs(phase.failures or {}) do
            phase_failures[#phase_failures + 1] = vim.tbl_extend("force", {
                phase = phase.name,
            }, failure)
        end
        for _, command in ipairs(phase.recovery or {}) do
            if not seen_recovery[command] then
                seen_recovery[command] = true
                recovery[#recovery + 1] = command
            end
        end
    end
    local warnings = {}
    local force_blocked = false
    if opts.force == true and not retain_projects then
        for _, failure in ipairs(phase_failures) do
            if force_warning_failure(failure) then
                warnings[#warnings + 1] = failure
            else
                force_blocked = true
            end
        end
        if #warnings > 0 and not force_blocked then
            reset_result.ok = true
        end
    end
    reset_result.warnings = warnings
    reset_result.discarded = opts.force == true and #warnings > 0
    reset_result.backend_confirmed = #warnings == 0
    reset_result.phase_failures = phase_failures
    reset_result.recovery = recovery
    reset_result.final_snapshot = full_snapshot()
    reset_result.blockers = reset_result.final_snapshot.blockers
    reset_result.blocker_count = reset_result.final_snapshot.blocker_count
    return reset_result
end

local function manifest_failed(reset_results)
    for _, phase in ipairs((reset_results or {})._phase_order or {}) do
        if phase.ok == false then
            return true
        end
    end
    return false
end

---Return the current resource-manager epoch.
---@return integer epoch Current epoch.
function M.epoch()
    return context.epoch()
end

---Return whether reset is currently executing.
---@return boolean resetting True while resource reset is in progress.
function M.in_reset()
    return context.in_reset()
end

---Return reset context state.
---@return table state Current reset state.
function M.state()
    return context.state()
end

---Build a coarse reset/project validity token.
---@param project? table Project associated with the token.
---@param kind? string Token purpose.
---@return table token Reset/project validity token.
function M.token(project, kind)
    return context.token(project, kind)
end

---Validate a token against the current reset/project epoch.
---@param token table? Token returned by `token`.
---@return boolean valid True when still valid.
---@return string? reason Invalid reason.
function M.valid_token(token)
    return context.valid_token(token)
end

---Stop live project/global resources using the existing resource driver.
---@param opts? table Reset controls.
---@return table summary Live-resource stop summary.
function M.stop_live_resources(opts)
    return require("typst.resources.drivers.live_resources").reset(opts or {})
end

---Execute the current reset manifest.
---@param opts? table Reset controls.
---@return table results Phase results keyed by manifest phase name.
function M.execute_manifest(opts)
    return resource_manifest().execute(opts or {})
end

---Reset runtime-owned resources through the ordered resource manager boundary.
---@param opts? table Reset controls.
---@return table summary Structured reset summary.
function M.reset(opts)
    opts = opts or {}
    local ctx = context.begin_reset(opts)
    local ok, reset_result = xpcall(function()
        local manifest_ok, reset_results = xpcall(function()
            return M.execute_manifest(opts)
        end, debug.traceback)

        if not manifest_ok then
            reset_results = {
                retain_projects = true,
                stop_resources = {
                    ok = false,
                    projects = 0,
                    failed = {
                        {
                            reason = "resource_manager_reset_exception",
                            result = reset_results,
                        },
                    },
                },
            }
        end

        local retain_projects = opts.force ~= true
            and reset_results.retain_projects == true
        if retain_projects then
            safe_log_add(
                "warn",
                "retaining projects after reset because active resources remain",
                reset_results.stop_resources
            )
        end
        if not retain_projects and not manifest_failed(reset_results) then
            safe_log_clear()
        end

        return attach_reset_metadata(
            reset_results.stop_resources,
            reset_results,
            ctx,
            opts
        )
    end, debug.traceback)

    pcall(context.end_reset)
    if not ok then
        reset_result = {
            ok = false,
            reason = "resource_manager_reset_exception",
            message = "Typst reset failed while building reset summary",
            error = tostring(reset_result),
            force = opts.force == true,
            epoch = ctx.epoch,
            started_at = ctx.started_at,
            finished_at = hrtime(),
        }
        safe_log_add("error", "resource manager reset failed", reset_result)
    end

    last_reset_summary = reset_result
    return reset_result
end

---Stop resources before process exit.
---@param opts? table Exit controls.
---@return table summary Exit cleanup summary.
function M.stop_for_exit_all(opts)
    return require("typst.resources.drivers.exit_cleanup").stop_for_exit_all(
        opts or {}
    )
end

---Try to stop resources before pruning an empty project.
---@param project table? Project state.
---@param opts? table Prune options.
---@return boolean attempted True when any cleanup/prune work was attempted.
---@return table summary Structured prune summary.
function M.stop_before_prune(project, opts)
    local result = require("typst.resources.drivers.prune").stop_before_prune(
        project,
        opts or {}
    )
    result.snapshot = project and M.snapshot(project) or nil
    return result.attempted == true, result
end

---Return whether a project owns resources that block pruning.
---@param project table? Project state.
---@return boolean active True when project resources are active.
function M.has_active_resources(project)
    return resource_session().has_active(project)
end

---Return a resource snapshot for one project or the whole runtime.
---@param project? table Project state.
---@param _opts? table Snapshot controls.
---@return table snapshot Resource snapshot.
function M.snapshot(project, _opts)
    if type(project) == "table" then
        return project_snapshot(project)
    end
    return full_snapshot()
end

---Return the latest reset summary, if any.
---@return table? summary Last reset summary.
function M.last_reset()
    return last_reset_summary
end

---Expose deferred-state queuing through the manager boundary.
---@param label string Deferred mutation label.
---@param fn fun() Mutation function.
---@param opts? {on_cancel?:fun(reason:string)}
---@return boolean deferred True when queued.
function M.defer_state_change(label, fn, opts)
    return require("typst.core.events").defer_state_change(label, fn, opts)
end

return M
