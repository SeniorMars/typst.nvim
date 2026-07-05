local metadata_artifacts = require("typst.metadata.artifacts")
local glyph_metrics = require("typst.metadata.glyph_metrics")

local M = {}

local SYMBOL_SCHEMA = metadata_artifacts.schemas.symbols
local decode_mpack_runtime = metadata_artifacts.decode_mpack_runtime
local expect_table = metadata_artifacts.expect_table
local expect_artifact = metadata_artifacts.expect_artifact
local validate_string_array = metadata_artifacts.validate_string_array
local validate_artifact_count = metadata_artifacts.validate_artifact_count
local artifact_file = metadata_artifacts.artifact_file
local artifact_cache = metadata_artifacts.artifact_cache
local metadata_error = metadata_artifacts.error

local function starts_with(value, prefix)
    return type(value) == "string" and value:sub(1, #prefix) == prefix
end

local function modifier_key(name)
    if type(name) ~= "string" or not name:find(".", 1, true) then
        return nil
    end

    local parts = {}
    for part in name:gmatch("[^%.]+") do
        parts[#parts + 1] = part
    end
    if #parts < 2 then
        return nil
    end

    local modifiers = {}
    for index = 2, #parts do
        modifiers[#modifiers + 1] = parts[index]
    end
    table.sort(modifiers)
    return parts[1] .. "\0" .. table.concat(modifiers, "\0")
end

function M.load(version, artifact_name)
    local artifacts = artifact_cache(version)
    if artifacts[artifact_name] then
        return artifacts[artifact_name]
    end

    local raw = expect_artifact(
        decode_mpack_runtime(artifact_file(version, artifact_name)),
        artifact_name,
        version,
        SYMBOL_SCHEMA,
        6
    )
    local names = expect_table(raw[3], artifact_name .. ".names")
    local glyphs = expect_table(raw[4], artifact_name .. ".glyphs")
    local deprecated_names =
        expect_table(raw[5], artifact_name .. ".deprecated_names")
    local deprecated_messages =
        expect_table(raw[6], artifact_name .. ".deprecated_messages")
    validate_string_array(names, artifact_name .. ".names")
    validate_string_array(glyphs, artifact_name .. ".glyphs")
    validate_string_array(
        deprecated_names,
        artifact_name .. ".deprecated_names"
    )
    validate_string_array(
        deprecated_messages,
        artifact_name .. ".deprecated_messages"
    )
    if #names ~= #glyphs then
        metadata_error(
            ("%s names and glyphs counts differ"):format(artifact_name)
        )
    end
    validate_artifact_count(version, artifact_name, #names)
    if #deprecated_names ~= #deprecated_messages then
        metadata_error(
            ("%s deprecated name and message counts differ"):format(
                artifact_name
            )
        )
    end
    local by_name = {}
    local deprecated = {}

    for index, name in ipairs(names) do
        by_name[name] = index
    end
    for index, name in ipairs(deprecated_names) do
        deprecated[name] = deprecated_messages[index]
    end

    artifacts[artifact_name] = {
        schema = raw[1],
        version = raw[2],
        names = names,
        glyphs = glyphs,
        by_name = by_name,
        deprecated = deprecated,
        records = {},
        variants = {},
        canonical_by_modifier_key = nil,
    }
    return artifacts[artifact_name]
end

function M.canonical_name(artifact, name)
    if artifact.by_name[name] then
        return name
    end

    local key = modifier_key(name)
    if not key then
        return nil
    end

    if not artifact.canonical_by_modifier_key then
        local by_modifier_key = {}
        for _, candidate in ipairs(artifact.names) do
            local candidate_key = modifier_key(candidate)
            if candidate_key and not by_modifier_key[candidate_key] then
                by_modifier_key[candidate_key] = candidate
            end
        end
        artifact.canonical_by_modifier_key = by_modifier_key
    end

    return artifact.canonical_by_modifier_key[key]
end

function M.variant_records(artifact, name)
    if artifact.variants[name] then
        return artifact.variants[name]
    end

    local prefix = name .. "."
    local variants = {}
    for index, candidate in ipairs(artifact.names) do
        if candidate == name or starts_with(candidate, prefix) then
            local metrics = glyph_metrics.for_glyph(artifact.glyphs[index])
            local modifiers = {}
            for modifier in candidate:gmatch("%.([^%.]+)") do
                modifiers[#modifiers + 1] = modifier
            end
            local variant = {
                canonical = candidate,
                modifiers = modifiers,
                glyph = artifact.glyphs[index],
                codepoints = vim.deepcopy(metrics.codepoints),
                scalar_count = metrics.scalar_count,
                grapheme_count = metrics.grapheme_count,
                display_width = metrics.display_width,
                nvim_conceal_safe = metrics.nvim_conceal_safe,
            }
            if artifact.deprecated[candidate] then
                variant.deprecated = artifact.deprecated[candidate]
            end
            variants[#variants + 1] = variant
        end
    end

    artifact.variants[name] = variants
    return variants
end

function M.record(artifact, name, kind, prefix)
    name = M.canonical_name(artifact, name)
    if not name then
        return nil
    end

    local cached = artifact.records[name]
    if cached then
        return cached
    end

    local index = artifact.by_name[name]
    local glyph = artifact.glyphs[index]
    local metrics = glyph_metrics.for_glyph(glyph)
    local symbol = {
        name = name,
        canonical = name,
        kind = kind,
        glyph = glyph,
        item_id = ("%s.%s"):format(prefix, name),
        symbol_id = ("%s.%s"):format(prefix, name),
        codepoints = vim.deepcopy(metrics.codepoints),
        scalar_count = metrics.scalar_count,
        grapheme_count = metrics.grapheme_count,
        display_width = metrics.display_width,
        nvim_conceal_safe = metrics.nvim_conceal_safe,
    }
    if artifact.deprecated[name] then
        symbol.deprecated = artifact.deprecated[name]
    end

    setmetatable(symbol, {
        __index = function(table_, key)
            if key == "variants" then
                local variants = M.variant_records(artifact, name)
                rawset(table_, "variants", variants)
                return variants
            end
        end,
    })
    artifact.records[name] = symbol
    return symbol
end

function M.reset()
    glyph_metrics.reset()
end

return M
