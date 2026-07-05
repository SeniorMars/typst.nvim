local metadata = require("typst.metadata")

local M = {}

-- User-facing symbol lookup accepts the forms people type in Typst documents
-- (`sym.foo`, `math.foo`, `emoji.foo`, and sometimes `std.foo`) and normalizes
-- them onto the versioned metadata catalog.

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

local function lower(value)
    return type(value) == "string" and value:lower() or ""
end

local function starts_with(value, prefix)
    return value:sub(1, #prefix) == prefix
end

local function contains(value, needle)
    return lower(value):find(needle, 1, true) ~= nil
end

local function provider_fields(catalog)
    return {
        provider = "metadata",
        provider_name = ("Typst %s symbol metadata"):format(catalog.version),
        provider_version = catalog.version,
        requested_version = catalog.requested_version,
        version_mismatch = catalog.version_mismatch,
    }
end

local function normalize_symbol(name, record, catalog, opts)
    opts = opts or {}
    local prefix = opts.prefix or "sym"
    local kind = opts.kind or "symbol"
    local category = opts.category or "symbols"
    local reference = opts.reference
        or "https://typst.app/docs/reference/symbols/sym/"
    local variants = opts.variants or metadata.symbol_variants
    local canonical_name = record.name or record.canonical or name
    local qualified = ("%s.%s"):format(prefix, canonical_name)
    local result = vim.tbl_extend("force", provider_fields(catalog), {
        id = qualified,
        kind = kind,
        name = canonical_name,
        qualified_name = qualified,
        title = canonical_name,
        item_id = record.symbol_id or qualified,
        summary = ("Typst %s `%s` renders as `%s`."):format(
            kind,
            qualified,
            record.glyph
        ),
        info = ("Glyph: `%s`"):format(record.glyph),
        signature = ("%s = %s"):format(canonical_name, record.glyph),
        category = category,
        parameters = {},
        returns = kind,
        keywords = {},
        glyph = record.glyph,
        variants = variants(canonical_name),
        source = {
            kind = "metadata",
            version = catalog.version,
        },
        links = {
            reference = reference,
        },
        raw = record,
    })
    return result
end

local function normalize_emoji(name, record, catalog)
    return normalize_symbol(name, record, catalog, {
        prefix = "emoji",
        kind = "emoji",
        category = "emoji",
        reference = "https://typst.app/docs/reference/symbols/emoji/",
        variants = metadata.emoji_variants,
    })
end

local function symbol_name(query)
    if starts_with(query, "sym.") then
        return query:sub(5)
    end

    return query
end

local function emoji_name(query)
    if starts_with(query, "emoji.") then
        return query:sub(7)
    end
end

function M.lookup(query)
    query = trim(query)
    if not query then
        return nil
    end

    if starts_with(query, "std.") then
        -- `std.` is a command/context-menu convenience prefix; symbols
        -- themselves are stored under sym/emoji names in the metadata catalog.
        query = query:sub(5)
    end

    local emoji_query = emoji_name(query)
    if emoji_query then
        local catalog = metadata.catalog()
        local emoji = metadata.emoji(emoji_query)
        if emoji then
            return normalize_emoji(emoji_query, emoji, catalog)
        end
    end

    local symbol_query = symbol_name(query)
    local catalog = metadata.catalog()
    local symbol = metadata.symbol(symbol_query)
    if symbol then
        return normalize_symbol(symbol_query, symbol, catalog)
    end

    if starts_with(query, "math.") then
        symbol_query = query:sub(6)
        symbol = metadata.symbol(symbol_query)
        if symbol then
            return normalize_symbol(symbol_query, symbol, catalog)
        end
    end
end

function M.search(query, opts)
    opts = opts or {}
    query = trim(query)
    if not query then
        return {}
    end

    local needle = lower(query)
    local limit = opts.limit or 40
    local catalog = metadata.catalog()
    local results = {}

    local function add(result)
        results[#results + 1] = result
        return #results >= limit
    end

    for name, record in metadata.symbol_iter() do
        if contains(name, needle) then
            if add(normalize_symbol(name, record, catalog)) then
                return results
            end
        end
    end

    for name, record in metadata.emoji_iter() do
        local qualified = "emoji." .. name
        if contains(name, needle) or contains(qualified, needle) then
            if add(normalize_emoji(name, record, catalog)) then
                return results
            end
        end
    end

    table.sort(results, function(left, right)
        return (left.qualified_name or left.name)
            < (right.qualified_name or right.name)
    end)
    return results
end

function M.complete(arglead)
    local raw = arglead or ""
    local needle = lower(raw)
    local items = {}

    local symbol_prefix = starts_with(needle, "sym.") and raw:sub(5) or raw
    for _, name in ipairs(metadata.symbol_complete(symbol_prefix)) do
        local qualified = "sym." .. name
        items[#items + 1] = qualified
    end

    if starts_with(needle, "emoji.") then
        for _, name in ipairs(metadata.emoji_complete(raw:sub(7))) do
            items[#items + 1] = "emoji." .. name
        end
    end

    return items
end

return M
