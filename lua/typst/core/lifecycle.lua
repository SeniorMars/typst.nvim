local M = {}

local cache_registry = require("typst.core.cache_registry")
local config = require("typst.config")
local ftplugin_state = require("typst.core.ftplugin_state")
local project = require("typst.project")
local index_service = require("typst.project.services.index")
local invalidation_service = require("typst.project.services.invalidation")
local util = require("typst.core.util")
local feature_signatures = {}
local window_feature_signatures = {}

local function conceal_module()
    return require("typst.conceal")
end

-- Shared teardown and editor-state lifecycle.
--
-- Buffer/window feature cleanup lives here. Project liveness cleanup belongs
-- to resources.supervisor; compatibility wrappers below delegate there.
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

--- Stop project-owned UI/compiler resources before removing an empty project.
---@param state? table Project state that may be pruned.
---@param log_message string Message logged when compiler shutdown is requested.
---@param prune_reason string Reason passed through to project pruning.
---@return boolean attempted True when teardown or prune work was attempted.
function M.stop_before_prune(state, log_message, prune_reason)
    return require("typst.resources.supervisor").stop_before_prune(
        state,
        log_message,
        prune_reason
    )
end

--- Stop project resources and clear buffer lifecycle state during plugin reset.
---@param opts? table Reset controls; `force=true` clears state even when stops fail.
---@return table summary Reset status with failed project details.
function M.reset_project_resources(opts)
    return require("typst.resources.supervisor").reset(opts)
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

    return not util.same_path(
        util.resolve_path(buffer_main, state.root),
        state.main
    )
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
