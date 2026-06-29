local config = require("typst.config")
local util = require("typst.core.util")

-- Converts collected outline items into display entries for quickfix and the
-- dedicated TOC window. Heading stacks are tracked per file so imported files do
-- not accidentally inherit the current heading from another source file.
local M = {}

local function item_text(project, item)
    local title = item.layer and ("[%s] %s"):format(item.layer, item.title)
        or item.title
    return ("%s%s [%s]"):format(
        string.rep("  ", math.max(item.level - 1, 0)),
        title,
        util.relpath(item.file, project.root)
    )
end

function M.qf_item(project, item)
    return {
        filename = item.file,
        lnum = item.lnum,
        col = item.col,
        text = item_text(project, item),
    }
end

local function item_key(item)
    return table.concat({
        item.file or "",
        tostring(item.lnum or 1),
        tostring(item.col or 1),
        item.layer or "heading",
        item.title or "",
    }, "\t")
end

local function layer_name(item)
    return item.layer or "heading"
end

function M.configured_visible_layers()
    local visible = {}
    for layer, enabled in pairs(config.unsafe_get().toc.visible_layers or {}) do
        visible[layer] = enabled
    end
    return visible
end

function M.layer_is_visible(state, layer)
    state.visible_layers = state.visible_layers or {}
    if state.visible_layers[layer] ~= nil then
        return state.visible_layers[layer]
    end

    local configured = config.unsafe_get().toc.visible_layers or {}
    return configured[layer] ~= false
end

local function hidden_by_collapsed_parent(stack, collapsed)
    for _, parent in ipairs(stack) do
        if collapsed[parent.key] then
            return true
        end
    end
    return false
end

function M.normalized_filter(filter)
    if type(filter) ~= "string" then
        return nil
    end

    filter = vim.trim(filter)
    if filter == "" then
        return nil
    end

    return filter:lower()
end

local function filter_text(project, item, layer)
    return table
        .concat({
            layer,
            item.title or "",
            util.relpath(item.file or project.main, project.root),
            item_text(project, item),
        }, "\n")
        :lower()
end

local function filter_matches(project, item, layer, filter)
    if not filter then
        return true
    end

    return filter_text(project, item, layer):find(filter, 1, true) ~= nil
end

function M.prepare(project, items, state)
    state.collapsed = state.collapsed or {}
    state.visible_layers = state.visible_layers or {}
    local filter = M.normalized_filter(state.filter)

    local entries = {}
    local stack_by_file = {}

    for _, item in ipairs(items) do
        local file_key = util.path_key(item.file or project.main)
        local stack = stack_by_file[file_key]
        if not stack then
            stack = {}
            stack_by_file[file_key] = stack
        end

        local layer = layer_name(item)
        local key = item_key(item)

        if layer == "heading" then
            while #stack > 0 and stack[#stack].level >= item.level do
                stack[#stack] = nil
            end
        end

        -- Filtering ignores collapsed parents so search can reveal matching
        -- children without permanently expanding the outline.
        local hidden = not filter
            and hidden_by_collapsed_parent(stack, state.collapsed)
        local display_level = item.level or 1
        if layer ~= "heading" and #stack > 0 then
            display_level = stack[#stack].level + 1
        end

        local entry = {
            item = item,
            key = key,
            layer = layer,
            display_level = display_level,
            has_children = false,
        }

        if #stack > 0 then
            stack[#stack].entry.has_children = true
        end

        if
            not hidden
            and M.layer_is_visible(state, layer)
            and filter_matches(project, item, layer, filter)
        then
            entries[#entries + 1] = entry
        end

        if layer == "heading" then
            stack[#stack + 1] = {
                key = key,
                level = item.level or 1,
                entry = entry,
            }
        end
    end

    return entries
end

function M.window_text(project, state, entry)
    local item = entry.item
    local marker = " "
    if entry.layer == "heading" and entry.has_children then
        marker = state.collapsed[entry.key] and "+" or "-"
    end

    local title = item.layer and ("[%s] %s"):format(item.layer, item.title)
        or item.title
    return ("%s%s %s [%s]"):format(
        string.rep("  ", math.max(entry.display_level - 1, 0)),
        marker,
        title,
        util.relpath(item.file, project.root)
    )
end

return M
