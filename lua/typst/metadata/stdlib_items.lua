local stdlib_core = require("typst.metadata.stdlib_core")
local stdlib_signatures = require("typst.metadata.stdlib_signatures")

local M = {}

local KIND = stdlib_core.KIND
local FLAG_CONTEXTUAL = stdlib_core.FLAG_CONTEXTUAL
local FLAG_DEPRECATED = stdlib_core.FLAG_DEPRECATED
local FLAG_HAS_CONSTRUCTOR = stdlib_core.FLAG_HAS_CONSTRUCTOR
local has_flag = stdlib_core.has_flag
local str = stdlib_core.str
local context_names = stdlib_core.context_names
local ensure_child_index = stdlib_core.ensure_child_index

local function item_summary(item)
    if not item then
        return nil
    end
    return {
        name = item.name,
        path = item.path,
        kind = item.kind,
        category = item.category,
        deprecated = item.deprecated,
        title = item.title,
        type = item.type,
        repr = item.repr,
    }
end

function M.row_summary(index, row)
    local flags = row[6] or 0
    local item = {
        path = str(index.strings, row[1]),
        name = str(index.strings, row[2]),
        kind = KIND[row[3]] or "unknown",
        category = str(index.strings, row[4]),
        contexts = context_names(row[5] or 0),
        contextual = has_flag(flags, FLAG_CONTEXTUAL),
        keywords = {},
        type = str(index.strings, row[9]),
        repr = str(index.strings, row[10]),
        title = str(index.strings, row[11]),
    }

    if has_flag(flags, FLAG_DEPRECATED) then
        item.deprecated = {
            message = str(index.strings, row[12]),
            until_version = str(index.strings, row[13]),
        }
    end

    for _, keyword_id in ipairs(row[14] or {}) do
        local keyword = str(index.strings, keyword_id)
        if keyword then
            item.keywords[#item.keywords + 1] = keyword
        end
    end

    return item
end

local function member_table(version, index, path)
    local child_paths = ensure_child_index(index)[path]
    if not child_paths then
        return nil
    end

    local members = {}
    for child, child_path in pairs(child_paths) do
        members[child] = item_summary(
            M.expand(version, index, child_path, { summary = true })
        )
    end
    return members
end

function M.expand(version, index, path, opts)
    opts = opts or {}
    if not opts.summary and index.item_cache[path] then
        return index.item_cache[path]
    end

    local row = index.rows[index.by_path[path]]
    if type(row) ~= "table" then
        return nil
    end

    local flags = row[6] or 0
    local item = {
        path = str(index.strings, row[1]),
        name = str(index.strings, row[2]),
        kind = KIND[row[3]] or "unknown",
        category = str(index.strings, row[4]),
        contexts = context_names(row[5] or 0),
        contextual = has_flag(flags, FLAG_CONTEXTUAL),
        keywords = {},
    }

    if has_flag(flags, FLAG_DEPRECATED) then
        item.deprecated = {
            message = str(index.strings, row[12]),
            until_version = str(index.strings, row[13]),
        }
    end

    item.type = str(index.strings, row[9])
    item.repr = str(index.strings, row[10])
    item.title = str(index.strings, row[11])

    for _, keyword_id in ipairs(row[14] or {}) do
        local keyword = str(index.strings, keyword_id)
        if keyword then
            item.keywords[#item.keywords + 1] = keyword
        end
    end

    if not opts.summary then
        local signature = stdlib_signatures.expand_id(version, row[7])
        if signature then
            item.parameters = signature.parameters
            item.returns = signature.returns
        end

        if has_flag(flags, FLAG_HAS_CONSTRUCTOR) then
            item.constructor = stdlib_signatures.expand_id(version, row[8])
        end

        item.members = member_table(version, index, item.path)
        index.item_cache[path] = item
    end

    return item
end

function M.items_table(version, index)
    if index.items_table then
        return index.items_table
    end

    local items = {}
    for _, path in ipairs(index.paths) do
        items[path] = M.expand(version, index, path)
    end

    index.items_table = items
    return items
end

function M.context_table(version, index, context_bit)
    index.context_tables = index.context_tables or {}
    if index.context_tables[context_bit] then
        return index.context_tables[context_bit]
    end

    local context_items = {}
    for _, path in ipairs(index.paths) do
        if not path:find(".", 1, true) then
            local row = index.rows[index.by_path[path]]
            if row and has_flag(row[5] or 0, context_bit) then
                context_items[path] = M.expand(version, index, path)
            end
        end
    end

    index.context_tables[context_bit] = context_items
    return context_items
end

M.items_proxy = M.items_table
M.context_proxy = M.context_table

return M
