local config = require("typst.config")
local helpers = require("typst.navigation.picker_backend_helpers")

---@class TypstPickerBackendHandlers
---@field open_item fun(item: table, opts: table)|nil

---@alias TypstPickerBackend fun(items: table[], opts: table, handlers: TypstPickerBackendHandlers): TypstPickerOpenResult

local M = {}

local function ui_select(items, opts, handlers)
    if not vim.ui or type(vim.ui.select) ~= "function" then
        return helpers.unavailable("ui_select", items)
    end

    if #items == 0 then
        return helpers.empty_result("ui_select", items)
    end

    vim.ui.select(items, {
        prompt = helpers.prompt_for(opts),
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if choice then
            helpers.open_item(handlers, choice, opts)
        end
    end)

    return {
        ok = true,
        backend = "ui_select",
        items = items,
    }
end

local function telescope(items, opts, handlers)
    local ok_pickers, pickers = pcall(require, "telescope.pickers")
    local ok_finders, finders = pcall(require, "telescope.finders")
    local ok_actions, actions = pcall(require, "telescope.actions")
    local ok_state, action_state = pcall(require, "telescope.actions.state")
    local ok_config, telescope_config = pcall(require, "telescope.config")
    if
        not (
            ok_pickers
            and ok_finders
            and ok_actions
            and ok_state
            and ok_config
        )
    then
        return helpers.unavailable("telescope", items)
    end

    if #items == 0 then
        return helpers.empty_result("telescope", items)
    end

    local picker_config = vim.tbl_deep_extend(
        "force",
        (config.unsafe_get().picker or {}).telescope or {},
        opts.telescope or {}
    )
    pickers
        .new(picker_config, {
            prompt_title = helpers.prompt_for(opts),
            finder = finders.new_table({
                results = items,
                entry_maker = function(item)
                    return {
                        value = item,
                        display = item.label,
                        ordinal = item.label,
                        filename = item.filename,
                        lnum = item.lnum,
                        col = item.col,
                    }
                end,
            }),
            sorter = telescope_config.values.generic_sorter(picker_config),
            attach_mappings = function(prompt_bufnr)
                actions.select_default:replace(function()
                    local selection = action_state.get_selected_entry()
                    actions.close(prompt_bufnr)
                    if selection and selection.value then
                        helpers.open_item(handlers, selection.value, opts)
                    end
                end)
                return true
            end,
        })
        :find()

    return {
        ok = true,
        backend = "telescope",
        items = items,
    }
end

local function fzf_lua(items, opts, handlers)
    local ok, fzf = pcall(require, "fzf-lua")
    if not ok or type(fzf.fzf_exec) ~= "function" then
        return helpers.unavailable("fzf_lua", items)
    end

    if #items == 0 then
        return helpers.empty_result("fzf_lua", items)
    end

    local entries, by_entry = helpers.indexed_entries(items)
    local picker_config = vim.tbl_deep_extend(
        "force",
        (config.unsafe_get().picker or {}).fzf_lua or {},
        opts.fzf_lua or {}
    )
    picker_config.prompt = picker_config.prompt
        or (helpers.prompt_for(opts) .. "> ")
    picker_config.actions = picker_config.actions or {}
    picker_config.actions["default"] = picker_config.actions["default"]
        or function(selected)
            local entry = type(selected) == "table" and selected[1] or selected
            helpers.open_item(handlers, by_entry[entry], opts)
        end

    fzf.fzf_exec(entries, picker_config)
    return {
        ok = true,
        backend = "fzf_lua",
        items = items,
    }
end

local function fzf_vim(items, opts, handlers)
    if #items == 0 then
        return helpers.empty_result("fzf_vim", items)
    end

    local entries, by_entry = helpers.indexed_entries(items)
    local picker_config = vim.tbl_deep_extend(
        "force",
        (config.unsafe_get().picker or {}).fzf_vim or {},
        opts.fzf_vim or {}
    )
    picker_config.source = picker_config.source or entries
    picker_config.options = picker_config.options
        or { "--prompt", helpers.prompt_for(opts) .. "> " }
    picker_config.sink = picker_config.sink
        or function(entry)
            helpers.open_item(handlers, by_entry[entry], opts)
        end

    local ok = pcall(vim.fn["fzf#run"], picker_config)
    if not ok then
        return helpers.unavailable("fzf_vim", items)
    end

    return {
        ok = true,
        backend = "fzf_vim",
        items = items,
    }
end

local function snacks(items, opts, handlers)
    local ok, snacks_mod = pcall(require, "snacks")
    if
        not ok
        or type(snacks_mod) ~= "table"
        or type(snacks_mod.picker) ~= "table"
    then
        return helpers.unavailable("snacks", items)
    end

    if #items == 0 then
        return helpers.empty_result("snacks", items)
    end

    local picker_config = vim.tbl_deep_extend(
        "force",
        (config.unsafe_get().picker or {}).snacks or {},
        opts.snacks or {}
    )
    if type(snacks_mod.picker.select) == "function" then
        snacks_mod.picker.select(items, {
            prompt = helpers.prompt_for(opts),
            format = function(item)
                return item.label
            end,
        }, function(choice)
            if choice then
                helpers.open_item(handlers, choice, opts)
            end
        end)
        return {
            ok = true,
            backend = "snacks",
            items = items,
        }
    end

    if type(snacks_mod.picker.pick) == "function" then
        picker_config.title = picker_config.title or helpers.prompt_for(opts)
        picker_config.items = picker_config.items
            or vim.tbl_map(function(item)
                return {
                    text = item.label,
                    item = item,
                    file = item.filename,
                    pos = { item.lnum, item.col },
                }
            end, items)
        picker_config.confirm = picker_config.confirm
            or function(_, item)
                helpers.open_item(handlers, item and (item.item or item), opts)
            end
        snacks_mod.picker.pick(picker_config)
        return {
            ok = true,
            backend = "snacks",
            items = items,
        }
    end

    return helpers.unavailable("snacks", items)
end

M.backends = {
    ui_select = ui_select,
    telescope = telescope,
    fzf_lua = fzf_lua,
    fzf_vim = fzf_vim,
    snacks = snacks,
}

return M
