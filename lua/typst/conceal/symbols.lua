local conceal_util = require("typst.conceal.util")
local metadata = require("typst.metadata")
local shadows = require("typst.conceal.shadows")

local M = {}

local display_safe = conceal_util.display_safe
local expression_source_range = conceal_util.expression_source_range
local normalize_symbol_name = conceal_util.normalize_symbol_name
local node_text = conceal_util.node_text
local range_text = conceal_util.range_text
local replacement_safe = conceal_util.replacement_safe

local function custom_math_replacement(custom_math, name, opts)
    local registered = custom_math and custom_math[name]
    if registered ~= nil then
        return registered, "User conceal registry"
    end

    local configured = opts.custom
        and opts.custom.math
        and opts.custom.math[name]
    if configured ~= nil then
        return configured, "User conceal config"
    end
end

function M.resolve(bufnr, node, opts, shadow_state, custom_math)
    if not opts.categories.math_symbols then
        return nil
    end

    local parent = node:parent()
    if parent and parent:type() == node:type() then
        return nil
    end

    local source = node_text(bufnr, node) or ""
    local name, explicit = normalize_symbol_name(source)
    local source_range = expression_source_range(node)
    if shadows.symbol_shadowed(name, explicit, shadow_state, source_range) then
        return nil
    end

    local record = metadata.symbol(name)
    local canonical_name = record and (record.name or record.canonical) or name
    local custom_replacement, custom_provider =
        custom_math_replacement(custom_math, name, opts)
    local custom_name = name
    if custom_replacement == nil and canonical_name ~= name then
        custom_replacement, custom_provider =
            custom_math_replacement(custom_math, canonical_name, opts)
        custom_name = canonical_name
    end
    if custom_replacement ~= nil then
        if not replacement_safe(custom_replacement, opts) then
            return nil
        end

        return {
            source = source_range,
            reveal = source_range,
            source_text = range_text(bufnr, source_range),
            replacement = custom_replacement,
            kind = "custom symbol",
            title = custom_name,
            symbol_id = nil,
            resolved_name = ("custom.math.%s"):format(custom_name),
            rule = "custom_math_symbols",
            category = "math_symbols",
            provider = custom_provider,
            provider_version = nil,
            requested_version = nil,
            version_mismatch = false,
            shadowed = explicit and "not applicable (explicit sym.*)" or "no",
            explicit = explicit,
            record = {
                kind = "custom symbol",
                glyph = custom_replacement,
                nvim_conceal_safe = true,
            },
        }
    end

    if not record or not display_safe(record, opts) then
        return nil
    end

    local catalog = metadata.catalog()
    return {
        source = source_range,
        reveal = source_range,
        source_text = range_text(bufnr, source_range),
        replacement = record.glyph,
        kind = record.kind or "symbol",
        title = record.title or canonical_name,
        symbol_id = record.symbol_id,
        resolved_name = record.symbol_id or ("sym." .. canonical_name),
        rule = "math_symbols",
        category = "math_symbols",
        provider = ("Typst %s metadata"):format(catalog.version),
        provider_version = catalog.version,
        requested_version = catalog.requested_version,
        version_mismatch = catalog.version_mismatch,
        shadowed = explicit and "not applicable (explicit sym.*)" or "no",
        explicit = explicit,
        record = record,
    }
end

return M
