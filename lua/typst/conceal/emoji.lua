local conceal_util = require("typst.conceal.util")
local lookup = require("typst.conceal.lookup")
local metadata = require("typst.metadata")

local M = {}

local display_safe = conceal_util.display_safe
local expression_source_range = conceal_util.expression_source_range
local normalize_emoji_name = conceal_util.normalize_emoji_name
local node_text = conceal_util.node_text
local range_text = conceal_util.range_text

function M.resolve(bufnr, node, opts)
    if not opts.categories.emoji then
        return nil
    end

    local parent = node:parent()
    if parent and parent:type() == node:type() then
        return nil
    end

    local source = node_text(bufnr, node) or ""
    local name = normalize_emoji_name(source)
    if not name then
        return nil
    end

    local maps = lookup.current(nil, opts)
    local record = maps.emojis[name] or metadata.emoji(name)
    if not record or not display_safe(record, opts) then
        return nil
    end

    local catalog = metadata.catalog()
    local source_range = expression_source_range(node)
    return {
        source = source_range,
        reveal = source_range,
        source_text = range_text(bufnr, source_range),
        replacement = record.glyph,
        kind = record.kind or "emoji",
        title = record.title,
        symbol_id = record.symbol_id,
        resolved_name = "emoji." .. name,
        rule = "emoji",
        category = "emoji",
        provider = ("Typst %s metadata"):format(catalog.version),
        provider_version = catalog.version,
        requested_version = catalog.requested_version,
        version_mismatch = catalog.version_mismatch,
        shadowed = "not applicable (explicit emoji.*)",
        explicit = true,
        record = record,
    }
end

return M
