local M = {}

local cache_registry = require("typst.core.cache_registry")
local config = require("typst.config")
local core_result = require("typst.core.result")
local ftplugin_state = require("typst.core.ftplugin_state")
local log = require("typst.core.log")
local project = require("typst.project")
local compiler_service = require("typst.project.services.compiler")
local index_service = require("typst.project.services.index")
local invalidation_service = require("typst.project.services.invalidation")
local project_operations = require("typst.project.services.operations")
local preview_service = require("typst.project.services.preview")
local util = require("typst.core.util")
local feature_signatures = {}
local window_feature_signatures = {}

local function compiler_module()
    return require("typst.compiler")
end

local function conceal_module()
    return require("typst.conceal")
end

local function toc_module()
    return require("typst.navigation.toc")
end

local function preview_module()
    return require("typst.integrations.typst_preview")
end

-- Shared teardown and editor-state lifecycle.
--
-- Buffer cleanup, project pruning, compiler shutdown, and preview shutdown meet
-- here so ftplugin reloads, buffer moves, reset, and exit all use the same
-- safety rules.
function M.buffer_augroup_name(bufnr)
    return ("typst_nvim_buf_%d"):format(bufnr)
end

function M.clear_buffer(bufnr)
    if not bufnr then
        return
    end

    feature_signatures[bufnr] = nil
    window_feature_signatures[bufnr] = nil
    cache_registry.forget_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    pcall(vim.api.nvim_del_augroup_by_name, M.buffer_augroup_name(bufnr))
    cache_registry.detach_buffer(bufnr)
    ftplugin_state.restore(bufnr)
end

local function buffer_feature_signature(bufnr)
    local state = project.get(bufnr)
    local project_index = state and index_service.get(state) or nil
    local invalidation = state and invalidation_service.get(state) or nil
    return table.concat({
        tostring(config.generation and config.generation() or 0),
        tostring(vim.api.nvim_buf_get_changedtick(bufnr)),
        tostring(vim.bo[bufnr].filetype or ""),
        tostring(state and state.key or ""),
        tostring(project_index and project_index.generation or 0),
        tostring(invalidation and invalidation.generation or 0),
    }, ":")
end

local function window_option(winid, name)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return ""
    end
    local ok, value = pcall(function()
        return vim.wo[winid][name]
    end)
    if not ok then
        return ""
    end
    return value
end

local function window_feature_signature(bufnr, winid)
    local state = project.get(bufnr)
    local opts = config.unsafe_get()
    return table.concat({
        tostring(config.generation and config.generation() or 0),
        tostring(bufnr),
        tostring(winid or ""),
        tostring(vim.bo[bufnr].filetype or ""),
        tostring(state and state.key or ""),
        tostring(opts.folds and opts.folds.enabled or false),
        tostring(opts.folds and opts.folds.mode or ""),
        tostring(opts.folds and opts.folds.foldlevel or ""),
        tostring(opts.folds and opts.folds.foldtext or false),
        tostring(opts.conceal and opts.conceal.enabled or false),
        tostring(opts.conceal and opts.conceal.conceallevel or ""),
        tostring(vim.b[bufnr].typst_conceal_enabled),
        tostring(window_option(winid, "conceallevel")),
        tostring(window_option(winid, "foldmethod")),
        tostring(window_option(winid, "foldexpr")),
        tostring(window_option(winid, "foldlevel")),
        tostring(window_option(winid, "foldtext")),
    }, ":")
end

local function should_apply_window_features(bufnr, winid, force)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return false
    end
    if vim.api.nvim_win_get_buf(winid) ~= bufnr then
        return false
    end

    local signatures = window_feature_signatures[bufnr] or {}
    window_feature_signatures[bufnr] = signatures
    local signature = window_feature_signature(bufnr, winid)
    if force or signatures[winid] ~= signature then
        return true
    end
    return false
end

local function mark_window_features_applied(bufnr, winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end
    local signatures = window_feature_signatures[bufnr] or {}
    window_feature_signatures[bufnr] = signatures
    signatures[winid] = window_feature_signature(bufnr, winid)
end

local function record_preview_stop_failure(state, prune_reason, result)
    preview_service.set(state, {
        active = true,
        stopping = type(result) == "table" and result.pending == true,
        status = "stopping_failed",
        last_result = type(result) == "table" and result or nil,
        last_error = type(result) == "table"
                and (result.error or result.message or result.reason or "pending")
            or result,
        stop_prune_reason = prune_reason,
    })
end

local function stop_preview_before_prune(state, prune_reason)
    local preview_state = preview_service.get(state) or {}
    if
        not state
        or next(state.bufs or {}) ~= nil
        or not preview_state.active
    then
        return nil
    end

    local ok, result = pcall(preview_module().stop, state, { lifecycle = true })
    if not ok then
        log.add("warn", "failed to stop preview before project prune", {
            main = state.main,
            reason = prune_reason,
            error = result,
        })
        record_preview_stop_failure(state, prune_reason, result)
        return false
    end

    if type(result) == "table" and result.pending == true then
        log.add("warn", "preview stop still pending before project prune", {
            main = state.main,
            reason = prune_reason,
        })
        record_preview_stop_failure(state, prune_reason, result)
        return false
    end

    if type(result) == "table" and result.ok == false then
        log.add("warn", "preview stop failed before project prune", {
            main = state.main,
            reason = prune_reason,
            stop_reason = result.reason,
            message = result.message,
        })
        record_preview_stop_failure(state, prune_reason, result)
        return false
    end

    if result == false then
        log.add("warn", "preview stop declined before project prune", {
            main = state.main,
            reason = prune_reason,
        })
        record_preview_stop_failure(state, prune_reason, result)
        return false
    end

    return true
end

local function close_toc_before_prune(state)
    if not state or next(state.bufs or {}) ~= nil then
        return false
    end

    local ok, closed = pcall(toc_module().close, state)
    if not ok then
        log.add("warn", "failed to close TOC before project prune", {
            main = state.main,
            error = closed,
        })
        return false
    end

    return closed == true
end

--- Stop project-owned UI/compiler resources before removing an empty project.
---@param state? table Project state that may be pruned.
---@param log_message string Message logged when compiler shutdown is requested.
---@param prune_reason string Reason passed through to project pruning.
---@return boolean attempted True when teardown or prune work was attempted.
function M.stop_before_prune(state, log_message, prune_reason)
    if not state or next(state.bufs or {}) ~= nil then
        return false
    end

    -- Only the last buffer for a project is allowed to trigger shutdown. Active
    -- preview/compile resources keep the project alive until they report a
    -- terminal stop result.
    local closed_toc = close_toc_before_prune(state)
    local stopped_preview = stop_preview_before_prune(state, prune_reason)
    local preview_failed = stopped_preview == false
    local compiler_state = compiler_service.get(state) or {}
    if not (compiler_state.watcher or compiler_state.process) then
        if preview_failed then
            return true
        end
        if stopped_preview or closed_toc then
            project.prune(state, prune_reason)
            return true
        end
        return false
    end

    log.add("info", log_message, { main = state.main })
    compiler_module().stop(state, function(result)
        if result and result.stopped and not preview_failed then
            project_operations.clear(state, "compile")
            project_operations.clear(state, "watch")
            project.prune(state, prune_reason)
            return
        end

        compiler_service.set(state, { status = "stopping_failed" })
        log.add("error", "retaining project with active resources", {
            main = state.main,
            reason = prune_reason,
            stop_result = result,
            preview_failed = preview_failed,
        })
    end)
    return true
end

local function clear_lifecycle_compile_handle(state)
    local compiler_state = compiler_service.get(state) or {}
    if state and compiler_state.stopping_compile then
        compiler_service.set(state, {
            clear = { "process", "active_compile_deps_path" },
            status = "idle",
        })
    end
end

local function stop_compiler_for_reset(state, opts)
    opts = opts or {}
    local compiler_state = compiler_service.get(state) or {}
    if
        not (
            compiler_state.process
            or compiler_state.watcher
            or compiler_state.stopping_compile
        )
    then
        compiler_service.set(state, {
            clear = { "process", "watcher" },
            status = "idle",
        })
        return {
            code = 0,
            stopped = true,
            idle = true,
        }
    end

    local done = false
    local result = nil
    local ok, err = pcall(compiler_module().stop, state, function(stop_result)
        result = stop_result
        done = true
    end)
    if not ok then
        log.add("warn", "failed to stop compiler during reset", {
            main = state.main,
            error = err,
        })
        result = {
            code = 1,
            stopped = false,
            error = err,
        }
        done = true
    end

    -- Reset is synchronous from the caller's point of view, but compiler.stop
    -- may complete through a callback. Wait briefly, then escalate so tests,
    -- :TypstReloadState, and VimLeavePre do not hang indefinitely.
    if not done then
        local timeout_ms = opts.timeout_ms or 1500
        vim.wait(timeout_ms, function()
            return done
        end, 10, false)
        if not done then
            log.add(
                "warn",
                "compiler stop timed out during reset; forcing shutdown",
                {
                    main = state.main,
                    timeout_ms = timeout_ms,
                }
            )
            local forced_ok, forced_result =
                pcall(compiler_module().stop_for_exit, state, {
                    timeout_ms = opts.force_timeout_ms or 250,
                    kill_timeout_ms = opts.force_kill_timeout_ms or 250,
                })
            result = forced_ok and forced_result
                or {
                    code = 1,
                    stopped = false,
                    error = forced_result,
                }
            done = true
        end
    end

    if core_result.is_confirmed_stopped(result) then
        clear_lifecycle_compile_handle(state)
        compiler_service.set(state, {
            clear = { "process", "watcher", "stopping_compile" },
            status = "idle",
        })
    else
        compiler_service.set(state, { status = "stopping_failed" })
        log.add(
            "error",
            "retaining compiler resources after reset stop failed",
            {
                main = state.main,
                result = result,
            }
        )
    end
    return result
end

local function reset_failed(summary, state, reason, result)
    summary.ok = false
    summary.failed[#summary.failed + 1] = {
        main = state and state.main,
        reason = reason,
        result = result,
    }
end

--- Stop project resources and clear buffer lifecycle state during plugin reset.
---@param opts? table Reset controls; `force=true` clears state even when stops fail.
---@return table summary Reset status with failed project details.
function M.reset_project_resources(opts)
    opts = opts or {}
    local states = vim.tbl_values(project.all())
    local summary = {
        ok = true,
        projects = #states,
        failed = {},
    }
    for _, state in ipairs(states) do
        state.resetting = true
        for bufnr in pairs(state.bufs or {}) do
            M.clear_buffer(bufnr)
        end

        pcall(toc_module().close, state)

        if (preview_service.get(state) or {}).active then
            local ok, result = pcall(
                preview_module().stop,
                state,
                { lifecycle = true, reset = true }
            )
            if not ok then
                log.add("warn", "failed to stop preview during reset", {
                    main = state.main,
                    error = result,
                })
                record_preview_stop_failure(state, "reset", result)
                reset_failed(summary, state, "preview_stop_error", result)
                if opts.force then
                    preview_module().clear_state(
                        state,
                        { lifecycle = true, reset = true, reason = "reset" }
                    )
                end
            elseif type(result) == "table" and result.pending == true then
                log.add("warn", "preview stop pending during reset", {
                    main = state.main,
                })
                record_preview_stop_failure(state, "reset", result)
                reset_failed(summary, state, "preview_stop_pending", result)
                if opts.force then
                    preview_module().clear_state(
                        state,
                        { lifecycle = true, reset = true, reason = "reset" }
                    )
                end
            elseif type(result) == "table" and result.ok == false then
                log.add("warn", "preview stop failed during reset", {
                    main = state.main,
                    reason = result.reason,
                    message = result.message,
                })
                record_preview_stop_failure(state, "reset", result)
                reset_failed(summary, state, "preview_stop_failed", result)
                if opts.force then
                    preview_module().clear_state(
                        state,
                        { lifecycle = true, reset = true, reason = "reset" }
                    )
                end
            elseif result == false then
                log.add("warn", "preview stop declined during reset", {
                    main = state.main,
                })
                record_preview_stop_failure(state, "reset", result)
                reset_failed(summary, state, "preview_stop_declined", result)
                if opts.force then
                    preview_module().clear_state(
                        state,
                        { lifecycle = true, reset = true, reason = "reset" }
                    )
                end
            end
        end

        local stopped = stop_compiler_for_reset(state, opts)
        if not core_result.is_confirmed_stopped(stopped) then
            reset_failed(summary, state, "compiler_stop_failed", stopped)
        end
        local cancelled = project_operations.cancel_project(state, {
            reason = "reset",
            timeout_ms = opts.operation_timeout_ms or 250,
            kill_timeout_ms = opts.operation_kill_timeout_ms or 250,
            wait_timeout_ms = opts.operation_wait_timeout_ms or 1000,
        })
        if cancelled.failed > 0 then
            log.add(
                "warn",
                "failed to cancel all project operations during reset",
                {
                    main = state.main,
                    summary = cancelled,
                }
            )
            reset_failed(summary, state, "operation_cancel_failed", cancelled)
        end
        if (cancelled.retained or 0) > 0 then
            log.add(
                "warn",
                "retained orphaned project operations during reset",
                {
                    main = state.main,
                    summary = cancelled,
                }
            )
            reset_failed(summary, state, "operation_orphan_retained", cancelled)
        end
        state.resetting = false
    end

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        M.clear_buffer(bufnr)
    end

    return summary
end

--- Check whether a buffer-local main setting no longer matches project state.
---@param bufnr integer Buffer whose `vim.b.typst_main` should be checked.
---@param state? table Previously attached project state.
---@return boolean changed True when the buffer should be re-resolved.
function M.explicit_main_changed(bufnr, state)
    if not state then
        return true
    end

    local buffer_main = util.get_buf_var(bufnr, "typst_main")
    if type(buffer_main) ~= "string" or buffer_main == "" then
        local resolution = state.resolutions and state.resolutions[bufnr]
        return resolution
            and resolution.main_source == "buffer variable vim.b.typst_main"
    end

    return util.resolve_path(buffer_main, state.root) ~= state.main
end

--- Move persisted explicit-main state after a buffer path changes.
---@param bufnr integer Renamed buffer.
---@param previous? table Project state recorded before the rename.
function M.migrate_persisted_main_for_rename(bufnr, previous)
    local resolution = previous
        and previous.resolutions
        and previous.resolutions[bufnr]
    local old_path = resolution and resolution.buffer
    local new_path = vim.api.nvim_buf_get_name(bufnr)
    if not old_path or new_path == "" then
        return
    end

    new_path = util.normalize(new_path)
    if old_path ~= new_path then
        require("typst.core.state").move_explicit_main(old_path, new_path)
    end
end

--- Apply buffer-local editor features managed by typst.nvim.
---@param bufnr integer Typst buffer receiving folds, indent, imaps, conceal, and syntax.
---@param opts? table Apply controls; `force=true` reapplies buffer-local features.
---@return table summary Applied feature groups.
function M.apply_buffer_features(bufnr, opts)
    opts = opts or {}
    local signature = buffer_feature_signature(bufnr)
    local apply_buffer = opts.skip_buffer ~= true
        and (
            opts.force == true
            or not feature_signatures[bufnr]
            or feature_signatures[bufnr] ~= signature
        )
    local winid = vim.api.nvim_get_current_win()
    local apply_window = should_apply_window_features(
        bufnr,
        winid,
        opts.force == true or opts.force_window == true or apply_buffer
    )

    if apply_window then
        require("typst.edit.folds").apply(bufnr, winid)
        conceal_module().apply(bufnr, winid)
        mark_window_features_applied(bufnr, winid)
    end

    if apply_buffer then
        require("typst.edit.indent").apply(bufnr)
        require("typst.edit.imaps").apply(bufnr)
        require("typst.edit.match_highlight").apply(bufnr)
        require("typst.syntax").apply(bufnr)
        feature_signatures[bufnr] = signature
    end

    return {
        buffer = apply_buffer,
        window = apply_window,
    }
end

--- Apply typst.nvim editor features in every visible window for a buffer.
---@param bufnr integer Typst buffer receiving buffer/window-local features.
---@param opts? table Apply controls; `force=true` reapplies features.
---@return table summary Applied feature groups and window count.
function M.apply_buffer_features_all_windows(bufnr, opts)
    opts = opts or {}
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return {
            buffer = false,
            window = false,
            windows = 0,
        }
    end

    local windows = require("typst.core.windows").all_for_buffer(bufnr)
    if #windows == 0 then
        local summary = M.apply_buffer_features(bufnr, opts)
        summary.windows = summary.window and 1 or 0
        return summary
    end

    local applied = {
        buffer = false,
        window = false,
        windows = 0,
    }
    for _, winid in ipairs(windows) do
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_call(winid, function()
                local summary = M.apply_buffer_features(
                    bufnr,
                    vim.tbl_extend("force", opts, {
                        skip_buffer = applied.buffer == true,
                        force_window = opts.force_window == true
                            or opts.force == true
                            or applied.buffer == true,
                    })
                )
                applied.buffer = applied.buffer or summary.buffer == true
                if summary.window == true then
                    applied.window = true
                    applied.windows = applied.windows + 1
                end
            end)
        end
    end
    if applied.windows == 0 then
        local summary = M.apply_buffer_features(bufnr, opts)
        summary.windows = summary.window and 1 or 0
        return summary
    end
    return applied
end

--- Register global lifecycle autocmds for cleanup and stale window state.
function M.register_autocmds()
    local group = vim.api.nvim_create_augroup("typst_nvim", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            require("typst.resources.supervisor").stop_for_exit_all()
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
            cache_registry.forget_window(args.match)
            ftplugin_state.forget_window(args.match)
            local winid = tonumber(args.match)
            if winid then
                for _, signatures in pairs(window_feature_signatures) do
                    signatures[winid] = nil
                end
            end
        end,
    })
end

return M
