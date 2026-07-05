local config = require("typst.config")
local completion_items = require("typst.completion.items")
local metadata = require("typst.metadata")

local M = {}

local fallback_color_names = {
    "aqua",
    "black",
    "blue",
    "eastern",
    "fuchsia",
    "gray",
    "green",
    "lime",
    "maroon",
    "navy",
    "olive",
    "orange",
    "purple",
    "red",
    "silver",
    "teal",
    "white",
    "yellow",
}

local fallback_color_maps = {
    "cividis",
    "coolwarm",
    "crest",
    "flare",
    "icefire",
    "inferno",
    "magma",
    "mako",
    "plasma",
    "rainbow",
    "rocket",
    "spectral",
    "turbo",
    "viridis",
    "vlag",
}

local cache = {
    version = nil,
    names = nil,
    maps = nil,
}

---@return string[]
local function fallback_names(values)
    local names = {}
    local seen = {}

    for _, name in ipairs(values or {}) do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    table.sort(names)
    return names
end

---@return string[]
local function sorted_names_from_members(item, predicate)
    local names = {}
    local seen = {}

    for name, member in pairs((item and item.members) or {}) do
        if type(name) == "string" and predicate(member) and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    table.sort(names)
    return names
end

---@return string[]
local function color_names(catalog)
    if type(catalog) ~= "table" then
        return fallback_names(fallback_color_names)
    end
    if cache.version ~= catalog.version then
        cache.version = catalog.version
        cache.names = nil
        cache.maps = nil
    end

    if cache.version == catalog.version and cache.names then
        return cache.names
    end

    local ok, names = pcall(function()
        return sorted_names_from_members(
            metadata.stdlib_item("color"),
            function(member)
                return member.kind == "constant" and member.type == "color"
            end
        )
    end)
    if not ok or type(names) ~= "table" or #names == 0 then
        names = fallback_names(fallback_color_names)
    end

    ---@cast names string[]
    cache.names = names
    return names
end

---@return string[]
local function color_map_names(catalog)
    if type(catalog) ~= "table" then
        return fallback_names(fallback_color_maps)
    end
    if cache.version ~= catalog.version then
        cache.version = catalog.version
        cache.names = nil
        cache.maps = nil
    end

    if cache.version == catalog.version and cache.maps then
        return cache.maps
    end

    local ok, names = pcall(function()
        return sorted_names_from_members(
            metadata.stdlib_item("color.map"),
            function(member)
                return member.kind == "constant"
            end
        )
    end)
    if not ok or type(names) ~= "table" or #names == 0 then
        names = fallback_names(fallback_color_maps)
    end

    ---@cast names string[]
    cache.maps = names
    return names
end

local function item(word, fields)
    fields = fields or {}
    return {
        word = word,
        abbr = word,
        menu = fields.map and "[Typst color map]" or "[Typst color]",
        kind = "v",
        info = completion_items.info({
            fields.map and ("Typst color map: " .. word)
                or ("Typst color: " .. word),
            fields.source,
        }),
        user_data = {
            typst = {
                kind = fields.map and "color_map" or "color",
                provider = fields.provider or "stdlib",
                semantic = false,
            },
        },
    }
end

function M.items(opts, base, catalog)
    local completion_config = config.unsafe_get().completion
    if
        opts.include_colors == false
        or completion_config.include_colors == false
    then
        return {}
    end

    local items = {}
    local seen = {}
    local catalog_version = type(catalog) == "table" and catalog.version
        or "fallback"
    local function add(word, fields)
        completion_items.add_unique(items, seen, word, function(value)
            return item(value, fields)
        end, { base = base })
    end

    for _, name in ipairs(color_names(catalog)) do
        add(name, {
            provider = "stdlib",
            source = ("Bundled Typst %s color"):format(catalog_version),
        })
        add("color." .. name, {
            provider = "stdlib",
            source = ("Bundled Typst %s color type member"):format(
                catalog_version
            ),
        })
    end
    for _, name in ipairs(color_map_names(catalog)) do
        add("color.map." .. name, {
            provider = "stdlib",
            source = ("Bundled Typst %s color map"):format(catalog_version),
            map = true,
        })
    end
    for _, name in ipairs(completion_config.color_names or {}) do
        add(name, { provider = "config", source = "Configured color name" })
    end

    table.sort(items, function(a, b)
        if a.menu == b.menu then
            return a.word < b.word
        end
        return a.menu < b.menu
    end)
    return items
end

return M
