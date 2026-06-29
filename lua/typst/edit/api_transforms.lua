local log = require("typst.core.log")
local tinymist = require("typst.integrations.tinymist")
local folds = require("typst.edit.folds")
local transaction = require("typst.edit.transaction")
local transform = require("typst.edit.transform")

local M = {}

---Public edit transforms prefer Tinymist structural edits when available, then
-- fall back to local syntax transforms. The local path keeps mappings useful in
-- buffers without an attached LSP client.

local function structural_notify(notify, action_name, result)
    if result.ok then
        local title = result.action and result.action.title or action_name
        notify(("Applied Tinymist action: %s"):format(title))
        return
    end

    log.add("warn", "tinymist structural action unavailable", {
        action = action_name,
        reason = result.reason,
    })
    notify(
        result.message or "Tinymist structural action unavailable",
        vim.log.levels.WARN
    )
end

local function structural_action_with_local_fallback(
    notify,
    action_name,
    local_action,
    opts
)
    opts = opts or {}
    local immediate = true
    local queued = nil
    local function finish(tinymist_result)
        if immediate then
            -- Tinymist can answer synchronously. Queue it until the caller has
            -- received the request result so sync and async paths share finish().
            queued = tinymist_result
            return nil
        end

        if tinymist_result.ok then
            structural_notify(notify, action_name, tinymist_result)
            return tinymist_result
        end

        return local_action(opts)
    end

    local result = tinymist.structural_action(
        action_name,
        vim.tbl_extend("force", opts, {
            callback = finish,
        })
    )
    immediate = false

    if queued then
        return finish(queued)
    end

    if result.pending then
        return result
    end

    if result.ok then
        structural_notify(notify, action_name, result)
        return result
    end

    return local_action(opts)
end

local function counted(action_opts, apply)
    return transaction.counted(action_opts, apply)
end

--- Attach transform helpers to the edit API table.
---@param api table Edit API table mutated in place.
---@param notify fun(message:string, level?:vim.log.levels|integer) Notification sink.
function M.attach(api, notify)
    function api.structural_action(action_name, action_opts)
        return counted(action_opts, function(opts)
            local result = tinymist.structural_action(
                action_name,
                vim.tbl_extend("force", opts, {
                    callback = function(tinymist_result)
                        structural_notify(notify, action_name, tinymist_result)
                    end,
                })
            )
            if result.provider ~= "tinymist" and not result.pending then
                structural_notify(notify, action_name, result)
            end
            return result
        end)
    end

    function api.promote_heading(action_opts)
        return counted(action_opts, function(opts)
            return structural_action_with_local_fallback(
                notify,
                "heading_promote",
                transform.promote_heading,
                opts
            )
        end)
    end

    function api.demote_heading(action_opts)
        return counted(action_opts, function(opts)
            return structural_action_with_local_fallback(
                notify,
                "heading_demote",
                transform.demote_heading,
                opts
            )
        end)
    end

    function api.refresh_folds(bufnr)
        return folds.refresh(bufnr)
    end

    function api.convert_equation(style, action_opts)
        action_opts = action_opts or {}
        style = style or "toggle"
        local action_name = ({
            toggle = "equation_toggle",
            inline = "equation_inline",
            block = "equation_block",
        })[style]

        if not action_name then
            error(
                'typst.nvim: equation style must be "toggle", "inline", or "block"'
            )
        end

        return counted(action_opts, function(opts)
            local immediate = true
            local queued = nil
            local function finish(result)
                if immediate then
                    -- See structural_action_with_local_fallback(): normalize
                    -- synchronous Tinymist callbacks through the same fallback
                    -- branch as delayed callbacks.
                    queued = result
                    return nil
                end

                if result.ok then
                    structural_notify(notify, action_name, result)
                    return result
                end

                return transform.convert_equation(style, opts)
            end

            local tinymist_result = tinymist.structural_action(
                action_name,
                vim.tbl_extend("force", opts, {
                    callback = finish,
                })
            )
            immediate = false

            if queued then
                return finish(queued)
            end

            if tinymist_result.pending then
                return tinymist_result
            end

            return transform.convert_equation(style, opts)
        end)
    end

    function api.toggle_equation_numbering(style, action_opts)
        return counted(action_opts, function(opts)
            return transform.toggle_equation_numbering(style, opts)
        end)
    end

    function api.toggle_fraction(action_opts)
        return counted(action_opts, transform.toggle_fraction)
    end

    function api.toggle_delimiter_size(action_opts)
        return counted(action_opts, transform.toggle_delimiter_size)
    end

    function api.toggle_line_break(action_opts)
        return counted(action_opts, transform.toggle_line_break)
    end

    function api.create_function(name, action_opts)
        return counted(action_opts, function(opts)
            return transform.create_function(name, opts)
        end)
    end

    function api.smart_close(action_opts)
        return counted(action_opts, transform.smart_close)
    end

    function api.convert_raw(style, action_opts)
        return counted(action_opts, function(opts)
            return transform.convert_raw(style, opts)
        end)
    end

    function api.unwrap_function(action_opts)
        return counted(action_opts, transform.unwrap_function)
    end

    function api.change_function(name, action_opts)
        return counted(action_opts, function(opts)
            return transform.change_function(name, opts)
        end)
    end

    function api.surround_delete_call(action_opts)
        return counted(action_opts, transform.surround_delete_call)
    end

    function api.surround_change_call(name, action_opts)
        return counted(action_opts, function(opts)
            return transform.surround_change_call(name, opts)
        end)
    end

    function api.change_delimiter(target, action_opts)
        return counted(action_opts, function(opts)
            return transform.change_delimiter(target, opts)
        end)
    end

    function api.surround_delete_delimiter(target, action_opts)
        return counted(action_opts, function(opts)
            return transform.surround_delete_delimiter(target, opts)
        end)
    end

    function api.surround_change_delimiter(target, action_opts)
        return counted(action_opts, function(opts)
            return transform.surround_change_delimiter(target, opts)
        end)
    end

    function api.surround_delete_block(action_opts)
        return counted(action_opts, transform.surround_delete_block)
    end

    function api.surround_change_block(target, action_opts)
        return counted(action_opts, function(opts)
            return transform.surround_change_block(target, opts)
        end)
    end

    function api.surround_delete_equation(action_opts)
        return counted(action_opts, transform.surround_delete_equation)
    end

    function api.surround_change_equation(target, action_opts)
        return counted(action_opts, function(opts)
            return transform.surround_change_equation(target, opts)
        end)
    end

    function api.change_delimiter_content(action_opts)
        return counted(action_opts, function(opts)
            return transform.change_delimiter("content", opts)
        end)
    end

    function api.change_delimiter_block(action_opts)
        return counted(action_opts, function(opts)
            return transform.change_delimiter("block", opts)
        end)
    end

    function api.change_delimiter_group(action_opts)
        return counted(action_opts, function(opts)
            return transform.change_delimiter("group", opts)
        end)
    end

    function api.change_delimiter_equation(action_opts)
        return counted(action_opts, function(opts)
            return transform.change_delimiter("equation", opts)
        end)
    end

    function api.split_arguments(action_opts)
        return counted(action_opts, transform.split_arguments)
    end

    function api.join_arguments(action_opts)
        return counted(action_opts, transform.join_arguments)
    end

    function api.toggle_arguments(action_opts)
        return counted(action_opts, transform.toggle_arguments)
    end

    function api.name_arguments(action_opts)
        return counted(action_opts, transform.name_arguments)
    end

    function api.toggle_trailing_comma(style, action_opts)
        return counted(action_opts, function(opts)
            return transform.toggle_trailing_comma(style, opts)
        end)
    end

    function api.add_trailing_comma(action_opts)
        return counted(action_opts, transform.add_trailing_comma)
    end

    function api.remove_trailing_comma(action_opts)
        return counted(action_opts, transform.remove_trailing_comma)
    end

    function api.toggle_label(action_opts)
        return counted(action_opts, transform.toggle_label)
    end

    function api.toggle_reference(action_opts)
        return counted(action_opts, transform.toggle_reference)
    end

    function api.toggle_label_reference(action_opts)
        return counted(action_opts, transform.toggle_label_reference)
    end

    function api.surround(kind, action_opts)
        return counted(action_opts, function(opts)
            return transform.surround(kind, opts)
        end)
    end

    function api.surround_function(name, action_opts)
        return counted(action_opts, function(opts)
            return transform.surround_function(name, opts)
        end)
    end

    function api.surround_content(action_opts)
        return counted(action_opts, transform.surround_content)
    end

    function api.surround_equation(action_opts)
        return counted(action_opts, transform.surround_equation)
    end

    function api.surround_figure(action_opts)
        return counted(action_opts, transform.surround_figure)
    end

    function api.surround_block(action_opts)
        return counted(action_opts, transform.surround_block)
    end

    function api.surround_strong(action_opts)
        return counted(action_opts, transform.surround_strong)
    end

    function api.surround_emph(action_opts)
        return counted(action_opts, transform.surround_emph)
    end

    function api.toggle_markup(kind, action_opts)
        return counted(action_opts, function(opts)
            return transform.toggle_markup(kind, opts)
        end)
    end

    function api.toggle_strong(action_opts)
        return counted(action_opts, transform.toggle_strong)
    end

    function api.toggle_emph(action_opts)
        return counted(action_opts, transform.toggle_emph)
    end

    function api.toggle_figure(action_opts)
        return counted(action_opts, transform.toggle_figure)
    end

    function api.toggle_list(kind, action_opts)
        return counted(action_opts, function(opts)
            return transform.toggle_list(kind, opts)
        end)
    end

    function api.toggle_bullet_list(action_opts)
        return counted(action_opts, transform.toggle_bullet_list)
    end

    function api.toggle_numbered_list(action_opts)
        return counted(action_opts, transform.toggle_numbered_list)
    end
end

return M
