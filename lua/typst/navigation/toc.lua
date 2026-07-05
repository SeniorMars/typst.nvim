local config = require("typst.config")
local collector = require("typst.navigation.toc_collect")
local toc_entries = require("typst.navigation.toc_entries")
local toc_quickfix = require("typst.navigation.toc_quickfix")
local toc_state = require("typst.navigation.toc_state")
local toc_window = require("typst.navigation.toc_window")
local log = require("typst.core.log")
local telemetry = require("typst.core.telemetry")

-- Table-of-contents presentation layer.
--
-- Collection is project-scoped, while display state such as collapsed headings,
-- filters, visible layers, and open windows belongs to the project TOC state so
-- multiple Typst projects can keep independent outlines in one Neovim session.
local M = {}

function M.collect(project, opts)
    return collector.collect(project, opts)
end

local function apply_mapping(bufnr, lhs, desc, callback)
    if lhs == nil or lhs == false or lhs == "" then
        return
    end

    vim.keymap.set("n", lhs, callback, {
        buffer = bufnr,
        silent = true,
        nowait = true,
        desc = desc,
    })
end

local function refresh_window(project, opts)
    return M.open(project, opts or {})
end

local function jump_to_toc_item(project, opts)
    local _, should_close = toc_window.open_entry(project, opts)
    if should_close then
        M.close(project)
    end
end

local function toggle_current_heading(project)
    local bufnr = vim.api.nvim_get_current_buf()
    local entry = toc_window.current_entry()
    if not entry or entry.layer ~= "heading" or not entry.has_children then
        return
    end

    local state = toc_state.for_project(project)
    state.collapsed = state.collapsed or {}
    state.collapsed[entry.key] = not state.collapsed[entry.key] or nil
    refresh_window(project, vim.b[bufnr].typst_toc_opts)
end

local function toggle_current_layer(project)
    local bufnr = vim.api.nvim_get_current_buf()
    local entry = toc_window.current_entry()
    if not entry then
        return
    end

    local state = toc_state.for_project(project)
    state.visible_layers = state.visible_layers
        or toc_entries.configured_visible_layers()
    state.visible_layers[entry.layer] =
        not toc_entries.layer_is_visible(state, entry.layer)
    refresh_window(project, vim.b[bufnr].typst_toc_opts)
end

local function prompt_filter(project)
    local bufnr = vim.api.nvim_get_current_buf()
    local state = toc_state.for_project(project)
    vim.ui.input({
        prompt = "Typst TOC filter: ",
        default = state.filter or "",
    }, function(value)
        if value == nil then
            return
        end
        M.filter(project, value, vim.b[bufnr].typst_toc_opts)
    end)
end

local function apply_quickfix_mappings(project, opts)
    local mappings = config.unsafe_get().toc.mappings
    if not mappings.enabled then
        return
    end

    local winid = toc_quickfix.winid()
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    vim.b[bufnr].typst_toc = true
    apply_mapping(
        bufnr,
        mappings.jump,
        "Jump to Typst TOC item",
        toc_quickfix.jump_to_item
    )
    apply_mapping(bufnr, mappings.close, "Close Typst TOC", toc_quickfix.close)
    apply_mapping(bufnr, mappings.refresh, "Refresh Typst TOC", function()
        M.open(project, opts)
    end)
end

local function apply_window_mappings(project, bufnr, opts)
    local mappings = config.unsafe_get().toc.mappings
    if not mappings.enabled then
        return
    end

    apply_mapping(bufnr, mappings.jump, "Jump to Typst TOC item", function()
        jump_to_toc_item(project)
    end)
    apply_mapping(bufnr, mappings.preview, "Preview Typst TOC item", function()
        jump_to_toc_item(project, { preview = true })
    end)
    apply_mapping(bufnr, mappings.close, "Close Typst TOC", function()
        M.close(project)
    end)
    apply_mapping(bufnr, mappings.refresh, "Refresh Typst TOC", function()
        M.open(project, opts)
    end)
    apply_mapping(bufnr, mappings.toggle, "Toggle Typst TOC heading", function()
        toggle_current_heading(project)
    end)
    apply_mapping(
        bufnr,
        mappings.toggle_layer,
        "Toggle Typst TOC layer",
        function()
            toggle_current_layer(project)
        end
    )
    apply_mapping(bufnr, mappings.filter, "Filter Typst TOC", function()
        prompt_filter(project)
    end)
    apply_mapping(
        bufnr,
        mappings.clear_filter,
        "Clear Typst TOC filter",
        function()
            M.clear_filter(project, vim.b[bufnr].typst_toc_opts)
        end
    )
end

local function set_quickfix(project, entries, opts)
    local qf_items = vim.tbl_map(function(item)
        return toc_entries.qf_item(project, item.item)
    end, entries)

    vim.fn.setqflist({}, "r", {
        title = toc_state.title(project),
        items = qf_items,
    })
    if opts.open ~= false then
        vim.cmd("copen")
        apply_quickfix_mappings(project, opts)
    end
end

local function presentation_mode(opts)
    if opts.quickfix == true then
        return "quickfix"
    end
    return opts.mode or config.unsafe_get().toc.mode
end

function M.open(project, opts)
    opts = opts or {}
    local current_bufnr = vim.api.nvim_get_current_buf()
    local source_bufnr
    if not toc_state.is_toc_buffer(current_bufnr) then
        source_bufnr = current_bufnr
    end
    local items = M.collect(project, opts)
    local state = toc_state.for_project(project)
    local entries = toc_entries.prepare(project, items, state)
    local mode = presentation_mode(opts)

    if mode == "quickfix" then
        set_quickfix(project, entries, opts)
    elseif opts.open ~= false then
        local _, bufnr = toc_window.open(project, entries, opts)
        apply_window_mappings(project, bufnr, opts)
        if source_bufnr then
            M.follow(project, source_bufnr)
        end
    end

    log.add("info", "toc opened", { items = #items, main = project.main })
    return items
end

function M.refresh_open(project, opts)
    opts = opts or {}
    local state = toc_state.for_project(project)
    if
        not toc_state.valid_win(state.winid)
        or not toc_state.valid_buf(state.bufnr)
    then
        return false
    end

    local current_win = vim.api.nvim_get_current_win()
    local current_opts = vim.b[state.bufnr].typst_toc_opts or {}
    local open_opts = vim.tbl_extend("force", current_opts, opts)
    M.open(project, open_opts)
    if opts.preserve_focus ~= false and toc_state.valid_win(current_win) then
        vim.api.nvim_set_current_win(current_win)
    end
    return true
end

function M.schedule_refresh(project, opts)
    opts = opts or {}
    local toc_config = config.unsafe_get().toc
    -- Only refresh while a TOC view is open. The collector may walk project
    -- files, so edits in normal buffers should not pay that cost unless there is
    -- visible UI to keep in sync.
    if not toc_config.auto_refresh or not M.is_open(project) then
        return false
    end

    local state = toc_state.for_project(project)
    toc_state.close_timer(state.refresh_timer)
    state.refresh_timer = vim.defer_fn(function()
        state.refresh_timer = nil
        M.refresh_open(
            project,
            vim.tbl_extend("force", opts, { preserve_focus = true })
        )
    end, toc_config.refresh_delay_ms)
    return true
end

function M.schedule_follow(project, bufnr, opts)
    opts = opts or {}
    local toc_config = config.unsafe_get().toc
    if not toc_config.follow_cursor or not M.is_open(project) then
        return false
    end

    local state = toc_state.for_project(project)
    local coalesced = state.follow_timer ~= nil
    local delay_ms = opts.delay_ms or toc_config.follow_delay_ms or 40
    state.follow_bufnr = bufnr
    toc_state.close_timer(state.follow_timer)
    telemetry.record("toc.follow.schedule", 0, {
        bufnr = bufnr,
        coalesced = coalesced,
        delay_ms = delay_ms,
        project_key = project and project.key or nil,
    })
    if coalesced then
        telemetry.record("toc.follow.coalesced", 0, {
            bufnr = bufnr,
            delay_ms = delay_ms,
            project_key = project and project.key or nil,
        })
    end
    state.follow_timer = vim.defer_fn(function()
        local follow_bufnr = state.follow_bufnr
        state.follow_timer = nil
        state.follow_bufnr = nil
        if not toc_config.follow_cursor or not M.is_open(project) then
            return
        end
        local started = telemetry.start()
        local line = M.follow(project, follow_bufnr, opts)
        telemetry.finish("toc.follow.execute", started, {
            bufnr = follow_bufnr,
            followed = line ~= nil,
            project_key = project and project.key or nil,
        })
    end, delay_ms)
    return true
end

function M.filter(project, value, opts)
    local state = toc_state.for_project(project)
    state.filter = toc_entries.normalized_filter(value)
    return M.open(project, opts or {})
end

function M.clear_filter(project, opts)
    local state = toc_state.for_project(project)
    state.filter = nil
    return M.open(project, opts or {})
end

function M.current_filter(project)
    return toc_state.for_project(project).filter
end

function M.follow(project, bufnr, opts)
    return toc_window.follow(project, bufnr, opts)
end

function M.current_line(project)
    return toc_window.current_line(project)
end

function M.is_open(project)
    if project then
        return toc_state.valid_win(toc_state.for_project(project).winid)
    end

    return toc_state.any_open()
end

function M.close(project)
    local closed_window = toc_state.close_window(toc_state.for_project(project))
    local closed_quickfix = toc_quickfix.close_title(toc_state.title(project))
    return closed_window or closed_quickfix
end

function M.close_current()
    local key = vim.b[vim.api.nvim_get_current_buf()].typst_toc_project
    if type(key) ~= "string" then
        return false
    end

    local state = toc_state.by_key(key)
    if not state then
        return false
    end

    return toc_state.close_window(state)
end

function M.quickfix_is_open()
    return toc_quickfix.is_toc()
end

function M.close_quickfix()
    if not toc_quickfix.matches_title() then
        return false
    end

    toc_quickfix.close()
    return true
end

return M
