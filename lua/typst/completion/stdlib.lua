local completion_items = require("typst.completion.items")
local metadata = require("typst.metadata")

local M = {}

local starts_with = completion_items.starts_with
local item_info = completion_items.info

local function symbol_item(name, record, catalog, opts)
    local word = opts.math and name or ("sym." .. name)
    if opts.explicit_symbol_prefix then
        word = "sym." .. name
    end

    return {
        word = word,
        abbr = ("%s %s"):format(name, record.glyph),
        menu = "[Typst symbol]",
        kind = "v",
        info = ("sym.%s = %s"):format(name, record.glyph),
        user_data = {
            typst = {
                id = "sym." .. name,
                kind = "symbol",
                provider = "stdlib",
                version = catalog.version,
            },
        },
    }
end

local function emoji_item(name, record, catalog)
    local word = "emoji." .. name
    return {
        word = word,
        abbr = ("%s %s"):format(name, record.glyph),
        menu = "[Typst emoji]",
        kind = "v",
        info = ("%s = %s"):format(word, record.glyph),
        user_data = {
            typst = {
                id = word,
                kind = "emoji",
                provider = "stdlib",
                version = catalog.version,
            },
        },
    }
end

local function stdlib_kind(item)
    if item.kind == "element" or item.kind == "function" then
        return "f"
    end
    if item.kind == "type" then
        return "t"
    end
    if item.kind == "module" then
        return "m"
    end
    return "v"
end

local function stdlib_menu(item)
    if item.deprecated then
        return "[Typst stdlib deprecated]"
    end
    if item.kind == "element" then
        return "[Typst element]"
    end
    if item.kind == "function" then
        return "[Typst function]"
    end
    if item.kind == "type" then
        return "[Typst type]"
    end
    if item.kind == "constant" then
        return "[Typst constant]"
    end
    return "[Typst stdlib]"
end

local function stdlib_item_info(item)
    local deprecated = item.deprecated
    return item_info({
        item.title,
        item.category and ("Category: " .. item.category) or nil,
        item.type and ("Type: " .. item.type) or nil,
        item.repr and ("Value: " .. item.repr) or nil,
        deprecated
                and (deprecated.until_version and ("Deprecated until Typst " .. deprecated.until_version .. ": " .. (deprecated.message or "")) or ("Deprecated: " .. (deprecated.message or "")))
            or nil,
    })
end

local function completion_prefix(base, context)
    if starts_with(base, "std.") then
        return "std.", base:sub(5), "global"
    end

    if starts_with(base, "math.") then
        return "math.", base:sub(6), "math"
    end

    return "", base, context == "math" and "math" or "global"
end

local function stdlib_item(item, catalog, qualifier)
    local word = (qualifier or "") .. item.path
    return {
        word = word,
        abbr = word,
        menu = stdlib_menu(item),
        kind = stdlib_kind(item),
        info = stdlib_item_info(item),
        user_data = {
            typst = {
                kind = item.kind,
                provider = "stdlib",
                semantic = false,
                path = item.path,
                category = item.category,
                deprecated = item.deprecated,
                version = catalog.version,
            },
        },
    }
end

local function stdlib_items(base, context, catalog, limit)
    local qualifier, prefix, stdlib_context = completion_prefix(base, context)
    local items = {}
    local seen = {}
    if limit and limit <= 0 then
        return items
    end

    for _, item in
        ipairs(metadata.stdlib_complete(prefix, stdlib_context, {
            limit = limit or 80,
            direct_children = true,
            exclude_symbols = true,
        }))
    do
        if item.kind ~= "symbol" and item.path and not seen[item.path] then
            seen[item.path] = true
            items[#items + 1] = stdlib_item(item, catalog, qualifier)
        end
    end

    table.sort(items, function(a, b)
        if a.menu == b.menu then
            return a.word < b.word
        end
        return a.menu < b.menu
    end)
    return items
end

function M.items(base, context, catalog, limit)
    local items = {}
    limit = limit or 80

    local function add(item)
        if #items >= limit then
            return true
        end
        items[#items + 1] = item
        return #items >= limit
    end

    for _, item in ipairs(stdlib_items(base, context, catalog, limit)) do
        if add(item) then
            return items
        end
    end

    local explicit_emoji_prefix = starts_with(base, "emoji.")
    if explicit_emoji_prefix then
        local emoji_base = base:sub(7)
        for _, name in
            ipairs(metadata.emoji_complete(emoji_base, limit - #items))
        do
            if add(emoji_item(name, metadata.emoji(name), catalog)) then
                return items
            end
        end
    end

    local explicit_symbol_prefix = starts_with(base, "sym.")
    local symbol_base = explicit_symbol_prefix and base:sub(5) or base
    for _, name in ipairs(metadata.symbol_complete(symbol_base, limit - #items)) do
        if
            add(symbol_item(name, metadata.symbol(name), catalog, {
                math = context == "math",
                explicit_symbol_prefix = explicit_symbol_prefix,
            }))
        then
            return items
        end
    end

    return items
end

return M
