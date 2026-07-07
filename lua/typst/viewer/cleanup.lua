local config = require("typst.config")
local events = require("typst.core.events")
local fragment_helpers = require("typst.compiler.fragment_helpers")
local log = require("typst.core.log")
local output_path_util = require("typst.compiler.output_path")
local preview_cache = require("typst.preview.cache")
local artifacts_service = require("typst.project.services.artifacts")
local compiler_service = require("typst.project.services.compiler")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local M = {}

local notify_user = require("typst.core.notify").user

local function remove_file(path)
    if
        type(path) ~= "string"
        or path == ""
        or vim.fn.filereadable(path) ~= 1
    then
        return false, nil
    end

    local ok, err = util.delete_checked(path)
    if not ok then
        return false, err
    end
    return true, nil
end

local function add_unique_path(paths, seen, path)
    if type(path) ~= "string" or path == "" then
        return
    end

    local key = util.path_key(path)
    if seen[key] then
        return
    end

    seen[key] = true
    paths[#paths + 1] = path
end

local function output_delete_allowed(state, output, opts)
    if opts.force == true then
        return true
    end

    local artifacts = require("typst.workflows.artifacts")
    local ok, reason = artifacts.owned_current(state, output)
    if ok then
        return true
    end
    return false, reason
end

local function remove_fragment_tree(path, state)
    if type(path) ~= "string" or path == "" then
        return false, nil, nil
    end

    path = util.canonical(path)
    if vim.fn.isdirectory(path) ~= 1 then
        return false, nil, nil
    end

    local ok, err = util.delete_owned_tree(path, {
        root = state.root,
        allow = function(candidate)
            return fragment_helpers.source_dir_cleanup_allowed(candidate, state)
        end,
        sentinel = fragment_helpers.source_sentinel_path(path),
        reason = "unsafe_fragment_source_dir",
    })
    if not ok then
        if type(err) == "table" then
            local reason = err.reason
            if
                reason == "unsafe_fragment_source_dir"
                or reason == "root_refused"
                or reason == "outside_root"
            then
                return false,
                    nil,
                    {
                        path = path,
                        reason = reason == "outside_root" and "outside_project"
                            or "unsafe_fragment_source_dir",
                    }
            end
        end
        return false, err, nil
    end
    return true, nil, nil
end

local function fragment_source_dirs(state, opts)
    local dirs = {}
    local seen = {}
    local cfg = config.unsafe_get()
    local compile = cfg.compile or {}
    local fragments = compile.fragments or {}

    add_unique_path(
        dirs,
        seen,
        fragment_helpers.resolve_source_dir(fragments, {}, opts or {}, state)
    )

    for _, template_opts in pairs(fragments.templates or {}) do
        if type(template_opts) == "table" then
            add_unique_path(
                dirs,
                seen,
                fragment_helpers.resolve_source_dir(
                    fragments,
                    template_opts,
                    {},
                    state
                )
            )
        end
    end

    return dirs
end

local function clean_temporary_artifacts(state, opts)
    local deleted = {}
    local failed = {}
    local skipped = {}
    local compiler_state = compiler_service.get(state) or {}
    local function clean_file(path)
        local removed, err = remove_file(path)
        if removed then
            deleted[#deleted + 1] = path
        elseif err then
            failed[#failed + 1] = { path = path, error = err }
        end
    end

    clean_file(compiler_state.active_compile_deps_path)
    if compiler_state.watcher then
        clean_file(compiler_state.watcher.deps_path)
    end

    for _, fragments_dir in ipairs(fragment_source_dirs(state, opts)) do
        local removed, err, skip = remove_fragment_tree(fragments_dir, state)
        if removed then
            deleted[#deleted + 1] = fragments_dir
        elseif err then
            failed[#failed + 1] = { path = fragments_dir, error = err }
        elseif skip then
            skipped[#skipped + 1] = skip
            log.add("warn", "skipped unsafe Typst fragment cleanup", skip)
        end
    end

    return deleted, failed, skipped
end

local function clean_preview_artifacts(state, opts)
    if not (opts.all or opts.outputs) then
        return {
            ok = true,
            deleted = {},
            failed = {},
            skipped = {},
            count = 0,
        }
    end

    return require("typst.workflows.artifacts").clean(state, {
        producer = "preview",
        force = opts.force,
    }, function() end)
end

local function empty_preview_clean()
    return {
        ok = true,
        deleted = {},
        failed = {},
        skipped = {},
        count = 0,
    }
end

local function clean_failure(state, notify, reason, message, fields)
    fields = fields or {}
    local preview_clean = fields.preview_clean or empty_preview_clean()
    local temporary = fields.temporary or {}
    local temporary_failed = fields.temporary_failed or {}
    local result = vim.tbl_extend("force", {
        ok = false,
        reason = reason,
        message = message,
        deleted = false,
        output_deleted = false,
        temporary = temporary,
        temporary_deleted = #temporary,
        temporary_failed = temporary_failed,
        temporary_failed_count = #temporary_failed,
        temporary_skipped = fields.temporary_skipped or {},
        temporary_skipped_count = #(fields.temporary_skipped or {}),
        preview_artifacts = preview_clean.deleted or {},
        preview_artifacts_deleted = #(preview_clean.deleted or {}),
        preview_artifacts_skipped = preview_clean.skipped or {},
        preview_artifacts_failed = preview_clean.failed or {},
        missing = fields.missing == true,
        notify_level = fields.notify_level or vim.log.levels.ERROR,
    }, fields)
    result.preview_clean = nil
    notify_user(notify, result.message, result.notify_level)
    log.add("warn", "Typst clean failed", {
        main = state.main,
        reason = result.reason,
        message = result.message,
        path = result.path or result.output,
        error = result.error,
    })
    return result
end

local function configured_output_path(state, compiler_state)
    if
        type(compiler_state.output) == "string"
        and compiler_state.output ~= ""
    then
        return compiler_state.output, nil
    end
    return output_path_util.safe_output_path(state, config.unsafe_get(), {
        operation = "clean",
    })
end

local function notify_clean_result(
    state,
    notify,
    output,
    deleted_output,
    deleted_temp,
    skipped_temp,
    preview_clean
)
    if deleted_output then
        local preview_count = #(preview_clean.deleted or {})
        local suffix = preview_count > 0
                and (" and %d preview artifact%s"):format(
                    preview_count,
                    preview_count == 1 and "" or "s"
                )
            or ""
        notify_user(
            notify,
            ("Cleaned %s%s"):format(util.relpath(output, state.root), suffix)
        )
    elseif #(preview_clean.deleted or {}) > 0 then
        local preview_count = #(preview_clean.deleted or {})
        notify_user(
            notify,
            ("Cleaned %d preview artifact%s"):format(
                preview_count,
                preview_count == 1 and "" or "s"
            )
        )
    elseif #(preview_clean.failed or {}) > 0 then
        notify_user(
            notify,
            "Failed to clean one or more preview artifacts",
            vim.log.levels.ERROR
        )
    elseif #(preview_clean.skipped or {}) > 0 then
        notify_user(
            notify,
            "Skipped unowned or modified preview artifacts",
            vim.log.levels.WARN
        )
    elseif #deleted_temp > 0 then
        notify_user(
            notify,
            ("Cleaned %d Typst temporary artifact%s"):format(
                #deleted_temp,
                #deleted_temp == 1 and "" or "s"
            )
        )
    elseif #skipped_temp > 0 then
        notify_user(
            notify,
            ("Skipped %d unsafe Typst temporary artifact director%s"):format(
                #skipped_temp,
                #skipped_temp == 1 and "y" or "ies"
            ),
            vim.log.levels.WARN
        )
    else
        notify_user(notify, "No Typst temporary artifacts to clean")
    end
end

local function clean_impl(state, opts, notify)
    opts = opts or {}

    local compiler_state = compiler_service.get(state) or {}
    if compiler_state.process or compiler_state.watcher then
        return clean_failure(
            state,
            notify,
            "active_compiler",
            "Stop the active Typst compiler before cleaning output",
            {
                process = compiler_state.process ~= nil,
                watcher = compiler_state.watcher ~= nil,
                notify_level = vim.log.levels.WARN,
            }
        )
    end

    local deleted_temp, failed, skipped_temp =
        clean_temporary_artifacts(state, opts)
    if #failed > 0 then
        local first = failed[1]
        return clean_failure(
            state,
            notify,
            "delete_failed",
            ("Failed to delete temporary artifact %s: %s"):format(
                first.path,
                tostring(first.error)
            ),
            {
                path = first.path,
                error = first.error,
                temporary = deleted_temp,
                temporary_failed = failed,
                temporary_skipped = skipped_temp,
            }
        )
    end
    local preview_clean = clean_preview_artifacts(state, opts)

    local output, output_error = configured_output_path(state, compiler_state)
    if output_error or not output then
        local result = vim.tbl_extend("force", output_error or {
            ok = false,
            reason = "output_path_invalid",
            message = "Invalid Typst clean output path",
        }, {
            deleted = false,
            output_deleted = false,
            temporary = deleted_temp,
            temporary_deleted = #deleted_temp,
            temporary_skipped = skipped_temp,
            temporary_skipped_count = #skipped_temp,
            preview_artifacts = preview_clean.deleted or {},
            preview_artifacts_deleted = #(preview_clean.deleted or {}),
            preview_artifacts_skipped = preview_clean.skipped or {},
            preview_artifacts_failed = preview_clean.failed or {},
            missing = true,
        })
        notify_user(notify, result.message, vim.log.levels.ERROR)
        log.add("warn", "clean skipped invalid Typst output path", {
            main = state.main,
            reason = result.reason,
            message = result.message,
        })
        return result
    end
    local deleted_output = false
    local missing_output = vim.fn.filereadable(output) ~= 1
    if opts.all or opts.outputs then
        if missing_output then
            log.add(
                "info",
                "clean skipped missing output",
                { output = output, main = state.main }
            )
        else
            local allowed, reason = output_delete_allowed(state, output, opts)
            if not allowed then
                return {
                    output = output,
                    deleted = false,
                    output_deleted = false,
                    temporary = deleted_temp,
                    temporary_deleted = #deleted_temp,
                    preview_artifacts = preview_clean.deleted or {},
                    preview_artifacts_deleted = #(preview_clean.deleted or {}),
                    preview_artifacts_skipped = preview_clean.skipped or {},
                    preview_artifacts_failed = preview_clean.failed or {},
                    missing = false,
                    skipped_output = true,
                    reason = reason,
                }
            end
            local ok, result = remove_file(output)
            if not ok then
                return clean_failure(
                    state,
                    notify,
                    "delete_failed",
                    ("Failed to delete output %s: %s"):format(
                        output,
                        tostring(result)
                    ),
                    {
                        output = output,
                        path = output,
                        error = result,
                        temporary = deleted_temp,
                        temporary_skipped = skipped_temp,
                        preview_clean = preview_clean,
                        missing = false,
                    }
                )
            end
            local artifact_state = artifacts_service.get(state) or {}
            if artifact_state.owned then
                artifact_state.owned[util.path_key(output)] = nil
                artifacts_service.set(state, { owned = artifact_state.owned })
            end
            deleted_output = true
            missing_output = false
        end
    end

    log.add("info", "cleaned Typst artifacts", {
        output = output,
        main = state.main,
        output_deleted = deleted_output,
        temp_deleted = #deleted_temp,
        temp_skipped = #skipped_temp,
        preview_artifacts_deleted = #(preview_clean.deleted or {}),
        preview_artifacts_skipped = #(preview_clean.skipped or {}),
    })
    events.emit("TypstOutputCleaned", state, {
        output = output,
        output_deleted = deleted_output,
        temporary = deleted_temp,
        temporary_skipped = skipped_temp,
        preview_artifacts = preview_clean.deleted or {},
        preview_artifacts_skipped = preview_clean.skipped or {},
        preview_artifacts_failed = preview_clean.failed or {},
    })
    notify_clean_result(
        state,
        notify,
        output,
        deleted_output,
        deleted_temp,
        skipped_temp,
        preview_clean
    )
    return {
        output = output,
        deleted = deleted_output,
        output_deleted = deleted_output,
        temporary = deleted_temp,
        temporary_deleted = #deleted_temp,
        temporary_skipped = skipped_temp,
        temporary_skipped_count = #skipped_temp,
        preview_artifacts = preview_clean.deleted or {},
        preview_artifacts_deleted = #(preview_clean.deleted or {}),
        preview_artifacts_skipped = preview_clean.skipped or {},
        preview_artifacts_failed = preview_clean.failed or {},
        missing = missing_output,
    }
end

--- Remove temporary Typst artifacts and optionally the owned compiler output.
---@param state table Project state whose artifacts should be cleaned.
---@param opts? table Clean options; `all`/`outputs` permit output deletion.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary with deleted output and temporary paths.
function M.clean(state, opts, notify)
    opts = opts or {}
    local result = telemetry.time("viewer.clean", function()
        return clean_impl(state, opts, notify)
    end, {
        all = opts.all == true,
        outputs = opts.outputs == true,
        force = opts.force == true,
    })
    return result
end

--- Remove temporary artifacts and request output cleanup for a project.
---@param state table Project state whose output should be cleaned.
---@param opts? table Clean options forwarded to `clean`.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary from `clean`.
function M.clean_output(state, opts, notify)
    opts = opts or {}
    opts.all = true
    local result = telemetry.time("viewer.clean_output", function()
        return clean_impl(state, opts, notify)
    end, {
        force = opts.force == true,
    })
    return result
end

local function clean_preview_impl(state, opts, notify)
    opts = opts or {}
    local result = preview_cache.clean(state, opts, function() end)
    local deleted = #(result.deleted or {})
    local skipped = #(result.skipped or {})
    local failed = #(result.failed or {})
    if failed > 0 then
        notify_user(
            notify,
            "Failed to clean one or more preview artifacts",
            vim.log.levels.ERROR
        )
    elseif deleted > 0 then
        notify_user(
            notify,
            ("Cleaned %d preview artifact%s"):format(
                deleted,
                deleted == 1 and "" or "s"
            )
        )
    elseif skipped > 0 then
        notify_user(
            notify,
            "Skipped active, unowned, or modified preview artifacts",
            vim.log.levels.WARN
        )
    else
        notify_user(notify, "No preview artifacts to clean")
    end

    return result
end

--- Remove preview-owned cache artifacts for a project.
---@param state table Project state whose preview artifacts should be cleaned.
---@param opts? table Clean controls; `force=true` removes modified owned artifacts.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary for preview-owned artifacts.
function M.clean_preview(state, opts, notify)
    opts = opts or {}
    local result = telemetry.time("viewer.clean_preview", function()
        return clean_preview_impl(state, opts, notify)
    end, {
        force = opts.force == true,
    })
    return result
end

return M
