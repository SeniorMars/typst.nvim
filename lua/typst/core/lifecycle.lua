local M = {}

local config = require("typst.config")
local events = require("typst.core.events")
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

local function call_loaded(module_name, method, ...)
    local module = package.loaded[module_name]
    if type(module) == "table" and type(module[method]) == "function" then
        return module[method](...)
    end
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
    call_loaded("typst.core.treesitter", "forget", bufnr)
    call_loaded("typst.edit.indent", "forget", bufnr)
    call_loaded("typst.bibliography.edit", "forget", bufnr)
    call_loaded("typst.formatting", "forget", bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    pcall(vim.api.nvim_del_augroup_by_name, M.buffer_augroup_name(bufnr))
    call_loaded("typst.conceal", "detach", bufnr)
    call_loaded("typst.edit.match_highlight", "detach", bufnr)
    ftplugin_state.restore(bufnr)
    call_loaded("typst.syntax", "clear", bufnr)
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

local function record_preview_stop_failure(state, prune_reason, result)
    preview_service.set(state, {
        active = true,
        status = "stopping_failed",
        last_result = type(result) == "table" and result or nil,
        last_error = type(result) == "table"
                and (result.error or result.message or result.reason)
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

    if result and (result.stopped or result.idle) then
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
        if not (stopped and (stopped.stopped or stopped.idle)) then
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
    local apply_buffer = opts.force == true
        or not feature_signatures[bufnr]
        or feature_signatures[bufnr] ~= signature

    require("typst.edit.folds").apply(bufnr)
    conceal_module().apply(bufnr)

    if apply_buffer then
        require("typst.edit.indent").apply(bufnr)
        require("typst.edit.imaps").apply(bufnr)
        require("typst.edit.match_highlight").apply(bufnr)
        require("typst.syntax").apply(bufnr)
        feature_signatures[bufnr] = signature
    end

    return {
        buffer = apply_buffer,
        window = true,
    }
end

--- Register global lifecycle autocmds for cleanup and stale window state.
function M.register_autocmds()
    local group = vim.api.nvim_create_augroup("typst_nvim", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            events.emit_global("TypstEventQuit", {
                projects = vim.tbl_count(project.all()),
            })
            for _, state in pairs(project.all()) do
                if (preview_service.get(state) or {}).active then
                    local ok, result = pcall(
                        preview_module().stop,
                        state,
                        { lifecycle = true }
                    )
                    if
                        not ok
                        or result == false
                        or (type(result) == "table" and result.ok == false)
                    then
                        preview_module().clear_state(
                            state,
                            { lifecycle = true, reason = "exit" }
                        )
                    end
                end
                compiler_module().stop_for_exit(state)
                local cancelled = project_operations.cancel_project(state, {
                    reason = "exit",
                    timeout_ms = 100,
                    kill_timeout_ms = 100,
                    wait_timeout_ms = 250,
                })
                if
                    (cancelled.failed or 0) > 0
                    or (cancelled.retained or 0) > 0
                then
                    log.add("warn", "project operations remained during exit", {
                        main = state.main,
                        summary = cancelled,
                    })
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
            call_loaded("typst.conceal", "_forget_window", args.match)
            ftplugin_state.forget_window(args.match)
        end,
    })
end

return M
