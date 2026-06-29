local config = require("typst.config")
local cursor_position = require("typst.completion.position")
local events = require("typst.core.events")
local fragment_helpers = require("typst.compiler.fragment_helpers")
local log = require("typst.core.log")
local output_path_util = require("typst.compiler.output_path")
local preview_cache = require("typst.preview.cache")
local typst_preview = require("typst.integrations.typst_preview")
local artifacts_service = require("typst.project.services.artifacts")
local compiler_service = require("typst.project.services.compiler")
local preview_service = require("typst.project.services.preview")
local util = require("typst.core.util")
local viewer = require("typst.viewer")

local M = {}

local notify_user = require("typst.core.notify").user

local function source_position(opts)
    opts = opts or {}
    if opts.line or opts.column then
        return {
            line = opts.line or vim.fn.line("."),
            column = opts.column or vim.fn.col("."),
        }
    end

    local resolved = cursor_position.resolve(opts)
    if resolved then
        return {
            line = resolved.row + 1,
            column = resolved.col + 1,
        }
    end

    return {
        line = vim.fn.line("."),
        column = vim.fn.col("."),
    }
end

--- Open the rendered output for a project with the configured viewer.
---@param state table Project state whose compiler output should be opened.
---@param opts? table Viewer options accepted for API symmetry.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return string|false path Opened output path, or false when no viewer opened it.
function M.view(state, opts, notify)
    local path = viewer.open(state)
    if path ~= false then
        notify_user(
            notify,
            ("Opened %s"):format(util.relpath(path, state.root))
        )
    end
    return path
end

--- Forward-search from the current source location to the viewer or preview.
---@param state table Project state whose main/output paths define the sync context.
---@param opts? table Forward-search options such as line, column, path, and notify.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table|boolean|string|nil result Backend sync result or failure payload.
function M.view_forward(state, opts, notify)
    opts = opts or {}
    local result = viewer.forward(state, opts)
    if
        type(result) == "table"
        and result.ok == false
        and result.reason == "unsupported"
    then
        -- VimTeX users expect forward search to work through the active preview
        -- when the PDF viewer has no direct forward-search backend.
        local viewer_result = result
        local preview_result = typst_preview.forward(state, opts)
        if type(preview_result) == "table" and preview_result.ok == false then
            if preview_result.reason ~= "unsupported" then
                result = preview_result
            else
                result = viewer_result
            end
        else
            result = preview_result
        end
    end

    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst viewer forward search is unavailable",
            vim.log.levels.WARN
        )
    elseif result ~= false then
        local position = source_position(opts)
        notify_user(
            notify,
            ("Forwarded %s:%d:%d"):format(
                util.relpath(state.main, state.root),
                position.line,
                position.column
            )
        )
    end

    return result
end

--- Jump from viewer-reported coordinates back into a Typst source buffer.
---@param state table Project state used to resolve inverse-search paths.
---@param opts? table Inverse-search options such as path, line, column, and notify.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table|boolean|nil result Source location result or failure payload.
function M.view_inverse(state, opts, notify)
    opts = opts or {}
    local result = viewer.inverse(state, opts)

    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst viewer inverse search is unavailable",
            vim.log.levels.WARN
        )
    elseif result ~= false and opts.notify ~= false then
        local location = type(result) == "table" and result or {}
        notify_user(
            notify,
            ("Viewer inverse jump %s:%d:%d"):format(
                util.relpath(
                    location.path or opts.path or state.main,
                    state.root
                ),
                location.line or opts.line or 1,
                location.column or opts.column or 1
            )
        )
    end

    return result
end

--- Return capabilities advertised by the configured PDF viewer backend.
---@return table capabilities Viewer backend capability flags.
function M.viewer_capabilities()
    return viewer.capabilities()
end

--- Return capabilities advertised by the Typst preview backend for a project.
---@param state table Project state used to inspect preview configuration.
---@return table capabilities Preview backend capability flags.
function M.preview_capabilities(state)
    return typst_preview.capabilities(state)
end

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

--- Remove temporary Typst artifacts and optionally the owned compiler output.
---@param state table Project state whose artifacts should be cleaned.
---@param opts? table Clean options; `all`/`outputs` permit output deletion.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary with deleted output and temporary paths.
function M.clean(state, opts, notify)
    opts = opts or {}

    local compiler_state = compiler_service.get(state) or {}
    if compiler_state.process or compiler_state.watcher then
        error(
            "typst.nvim: stop the active Typst compiler before cleaning output"
        )
    end

    local deleted_temp, failed, skipped_temp =
        clean_temporary_artifacts(state, opts)
    if #failed > 0 then
        local first = failed[1]
        error(
            ("typst.nvim: failed to delete temporary artifact %s: %s"):format(
                first.path,
                tostring(first.error)
            )
        )
    end
    local preview_clean = clean_preview_artifacts(state, opts)

    local output = compiler_state.output
        or output_path_util.output_path(state, config.unsafe_get())
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
                error(
                    ("typst.nvim: failed to delete output %s: %s"):format(
                        output,
                        tostring(result)
                    )
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

--- Remove temporary artifacts and request output cleanup for a project.
--- Changed or unowned outputs are skipped unless `opts.force` is true.
---@param state table Project state whose output should be cleaned.
---@param opts? table Clean options forwarded to `clean`.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary from `clean`.
function M.clean_output(state, opts, notify)
    opts = opts or {}
    opts.all = true
    return M.clean(state, opts, notify)
end

--- Remove preview-owned cache artifacts for a project.
---@param state table Project state whose preview artifacts should be cleaned.
---@param opts? table Clean controls; `force=true` removes modified owned artifacts.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Clean summary for preview-owned artifacts.
function M.clean_preview(state, opts, notify)
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

--- Start Typst preview for a project.
---@param state table Project state passed to the preview integration.
---@param opts? table Preview options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|boolean result Preview backend result.
function M.preview(state, opts, notify)
    opts = opts or {}
    local result = typst_preview.open(state, opts)
    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst preview is unavailable",
            vim.log.levels.WARN
        )
    elseif result == true then
        notify_user(
            notify,
            ("Previewing %s"):format(util.relpath(state.main, state.root))
        )
    end
    return result
end

--- Open the native browser preview target regardless of the default target.
---@param state table Project state passed to the preview integration.
---@param opts? table Preview options.
---@param notify? fun(message:string, level?:integer) Notification sink.
---@return table|boolean result Preview backend result.
function M.preview_open_browser(state, opts, notify)
    opts = vim.tbl_extend("force", opts or {}, {
        native = "browser",
    })
    return M.preview(state, opts, notify)
end

--- Refresh an active preview backend from Neovim.
---@param state table Project state whose preview should reload.
---@param opts? table Refresh options.
---@param notify? fun(message:string, level?:integer) Notification sink.
---@return table|boolean|nil result Refresh result or unsupported payload.
function M.preview_reload(state, opts, notify)
    opts = opts or {}
    local preview_state = preview_service.get(state) or {}
    if preview_state.active ~= true then
        local result = {
            ok = false,
            reason = "inactive_preview",
            message = "No active Typst preview is available to reload",
        }
        notify_user(notify, result.message, vim.log.levels.WARN)
        return result
    end

    local result = typst_preview.refresh(state, {
        code = 0,
        manual = true,
        generation = vim.uv.hrtime(),
    }, opts)
    if type(result) == "table" and result.pending == true then
        if type(result.on_finish) == "function" then
            result:on_finish(function(finished)
                if type(finished) == "table" and finished.ok == false then
                    notify_user(
                        notify,
                        finished.message or "Typst preview reload failed",
                        vim.log.levels.WARN
                    )
                else
                    notify_user(notify, "Reloaded Typst preview")
                end
            end)
        end
        return result
    end
    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst preview reload failed",
            vim.log.levels.WARN
        )
    else
        notify_user(notify, "Reloaded Typst preview")
    end
    return result
end

--- Return preview backend/cache status for a project.
---@param state table Project state whose preview should be inspected.
---@param opts? table Status display options.
---@param notify? fun(message:string, level?:integer) Notification sink.
---@return table status Preview status payload.
function M.preview_status(state, opts, notify)
    opts = opts or {}
    local preview_state = preview_service.get(state) or {}
    local cache_status = preview_cache.status(state)
    local lines = require("typst.ui.reports").preview_status_lines(state)
    if opts.echo ~= false then
        require("typst.ui.reports").echo_lines(lines)
    elseif opts.notify ~= false then
        notify_user(
            notify,
            ("Preview %s, cache %d entries"):format(
                preview_state.active and "active" or "inactive",
                cache_status.count
            )
        )
    end
    return {
        ok = true,
        active = preview_state.active == true,
        backend = preview_state.active and preview_state.active_backend
            or preview_state.last_backend,
        cache = cache_status,
        lines = lines,
    }
end

--- Stop Typst preview for a project.
---@param state table Project state passed to the preview integration.
---@param opts? table Preview stop options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|boolean result Preview backend result.
function M.preview_stop(state, opts, notify)
    opts = opts or {}
    local result = typst_preview.stop(state, opts)

    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst preview stop is unavailable",
            vim.log.levels.WARN
        )
    elseif result ~= false then
        notify_user(
            notify,
            ("Preview stopped for %s"):format(
                util.relpath(state.main, state.root)
            )
        )
    end

    return result
end

--- Toggle Typst preview for a project.
---@param state table Project state passed to the preview integration.
---@param opts? table Preview toggle options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|boolean result Preview backend result.
function M.preview_toggle(state, opts, notify)
    opts = opts or {}
    local result = typst_preview.toggle(state, opts)

    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst preview toggle is unavailable",
            vim.log.levels.WARN
        )
    elseif (preview_service.get(state) or {}).active then
        notify_user(
            notify,
            ("Previewing %s"):format(util.relpath(state.main, state.root))
        )
    else
        notify_user(
            notify,
            ("Preview stopped for %s"):format(
                util.relpath(state.main, state.root)
            )
        )
    end

    return result
end

--- Run inverse search through the Typst preview integration.
---@param state table Project state used to resolve source locations.
---@param opts? table Preview inverse-search options.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|boolean result Preview inverse-search result or failure payload.
function M.preview_inverse(state, opts, notify)
    opts = opts or {}
    local result = typst_preview.inverse(state, opts)

    if type(result) == "table" and result.ok == false then
        notify_user(
            notify,
            result.message or "Typst preview inverse search is unavailable",
            vim.log.levels.WARN
        )
    elseif result ~= false and opts.notify ~= false then
        local location = type(result) == "table" and result or {}
        notify_user(
            notify,
            ("Preview inverse jump %s:%d:%d"):format(
                util.relpath(location.path or state.main, state.root),
                location.line or opts.line or 1,
                location.column or opts.column or 1
            )
        )
    end

    return result
end

return M
