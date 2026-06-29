local config = require("typst.config")
local metadata_artifacts = require("typst.metadata.artifacts")
local font_discovery = require("typst.metadata.font_discovery")
local metadata_stdlib = require("typst.metadata.stdlib")
local symbol_metadata = require("typst.metadata.symbols")

local M = {}

local cache = {
    catalog = nil,
}
local generation = 0

local SHORTHAND_SCHEMA = metadata_artifacts.schemas.shorthands
local decode_mpack_runtime = metadata_artifacts.decode_mpack_runtime
local expect_table = metadata_artifacts.expect_table
local expect_string = metadata_artifacts.expect_string
local expect_array_len = metadata_artifacts.expect_array_len
local expect_artifact = metadata_artifacts.expect_artifact
local validate_artifact_count = metadata_artifacts.validate_artifact_count
local artifact_file = metadata_artifacts.artifact_file
local artifact_cache = metadata_artifacts.artifact_cache

local function shorthands_view(version)
    local artifacts = artifact_cache(version)
    if artifacts.shorthands then
        return artifacts.shorthands
    end

    local raw = expect_artifact(
        decode_mpack_runtime(artifact_file(version, "shorthands")),
        "shorthands",
        version,
        SHORTHAND_SCHEMA,
        3
    )
    local contexts = expect_table(raw[3], "shorthands.contexts")
    local count = 0
    local view = {
        schema = raw[1],
        version = raw[2],
    }

    for context_index, context in ipairs(contexts) do
        expect_array_len(
            context,
            2,
            ("shorthands.contexts[%d]"):format(context_index)
        )
        local name = context[1]
        expect_string(
            name,
            ("shorthands.contexts[%d].name"):format(context_index)
        )
        expect_table(
            context[2],
            ("shorthands.contexts[%d].entries"):format(context_index)
        )
        local target = {
            source_to_glyph = {},
            glyph_to_source = {},
            entries = {},
        }
        for entry_index, entry in ipairs(context[2]) do
            expect_array_len(
                entry,
                2,
                ("shorthands.contexts[%d].entries[%d]"):format(
                    context_index,
                    entry_index
                )
            )
            local source = entry[1]
            local glyph = entry[2]
            expect_string(
                source,
                ("shorthands.contexts[%d].entries[%d].source"):format(
                    context_index,
                    entry_index
                )
            )
            expect_string(
                glyph,
                ("shorthands.contexts[%d].entries[%d].glyph"):format(
                    context_index,
                    entry_index
                )
            )
            count = count + 1
            target.source_to_glyph[source] = glyph
            target.glyph_to_source[glyph] = target.glyph_to_source[glyph]
                or source
            target.entries[#target.entries + 1] = {
                source = source,
                glyph = glyph,
            }
        end
        view[name] = target
    end

    validate_artifact_count(version, "shorthands", count)
    artifacts.shorthands = view
    return view
end

local function install_catalog_maps(catalog)
    catalog.symbols =
        symbol_metadata.map(catalog.version, "symbols", "symbol", "sym")
    catalog.emojis =
        symbol_metadata.map(catalog.version, "emojis", "emoji", "emoji")
end

function M.available_versions()
    return vim.deepcopy(metadata_artifacts.load_versions())
end

function M.catalog(opts)
    opts = opts or {}
    local requested = opts.version or config.unsafe_get().metadata_version
    if not requested and opts.detect_version then
        requested = metadata_artifacts.detect_typst_version(
            config.unsafe_get().executable
        )
    end

    if cache.catalog and cache.catalog.requested_version == requested then
        return cache.catalog
    end

    local version, mismatch = metadata_artifacts.choose_version(requested)
    local selected_manifest = metadata_artifacts.manifest(version)
    cache.catalog = {
        kind = "typst",
        version = version,
        requested_version = requested,
        version_mismatch = mismatch,
        manifest = selected_manifest,
        artifacts = selected_manifest.artifacts or {},
    }
    install_catalog_maps(cache.catalog)
    return cache.catalog
end

function M.symbol(name)
    if type(name) ~= "string" then
        return nil
    end
    local catalog = M.catalog()
    return symbol_metadata.record(
        catalog.version,
        "symbols",
        name,
        "symbol",
        "sym"
    )
end

function M.symbol_glyph(name)
    local record = M.symbol(name)
    return record and record.glyph or nil
end

function M.symbol_variants(name)
    local catalog = M.catalog()
    return symbol_metadata.variant_names(catalog.version, "symbols", name)
end

function M.symbol_variant_records(name)
    local catalog = M.catalog()
    return symbol_metadata.variant_records(catalog.version, "symbols", name)
end

function M.symbol_deprecation(name)
    local catalog = M.catalog()
    return symbol_metadata.deprecation(catalog.version, "symbols", name)
end

function M.symbol_names()
    local catalog = M.catalog()
    return symbol_metadata.names(catalog.version, "symbols")
end

function M.symbol_iter()
    local catalog = M.catalog()
    return symbol_metadata.iter(catalog.version, "symbols", "symbol", "sym")
end

function M.symbol_complete(prefix, limit)
    local catalog = M.catalog()
    return symbol_metadata.complete(catalog.version, "symbols", prefix, limit)
end

function M.emoji(name)
    if type(name) ~= "string" then
        return nil
    end
    local catalog = M.catalog()
    return symbol_metadata.record(
        catalog.version,
        "emojis",
        name,
        "emoji",
        "emoji"
    )
end

function M.emoji_glyph(name)
    local record = M.emoji(name)
    return record and record.glyph or nil
end

function M.emoji_variants(name)
    local catalog = M.catalog()
    return symbol_metadata.variant_names(catalog.version, "emojis", name)
end

function M.emoji_variant_records(name)
    local catalog = M.catalog()
    return symbol_metadata.variant_records(catalog.version, "emojis", name)
end

function M.emoji_names()
    local catalog = M.catalog()
    return symbol_metadata.names(catalog.version, "emojis")
end

function M.emoji_iter()
    local catalog = M.catalog()
    return symbol_metadata.iter(catalog.version, "emojis", "emoji", "emoji")
end

function M.emoji_complete(prefix, limit)
    local catalog = M.catalog()
    return symbol_metadata.complete(catalog.version, "emojis", prefix, limit)
end

function M.emojis()
    local catalog = M.catalog()
    return catalog.emojis
end

function M.stdlib()
    local catalog = M.catalog()
    if not catalog.stdlib then
        catalog.stdlib = metadata_stdlib.view(catalog.version)
    end
    return catalog.stdlib
end

function M.stdlib_item(path)
    if type(path) ~= "string" then
        return nil
    end
    local catalog = M.catalog()
    return metadata_stdlib.item(catalog.version, path)
end

function M.stdlib_complete(prefix, context, opts)
    local catalog = M.catalog()
    return metadata_stdlib.complete(catalog.version, prefix, context, opts)
end

function M.stdlib_param_docs(path, name)
    if
        type(path) ~= "string"
        or path == ""
        or type(name) ~= "string"
        or name == ""
    then
        return nil
    end

    local catalog = M.catalog()
    return metadata_stdlib.param_docs(catalog.version, path, name)
end

function M.stdlib_constants_by_type(type_name, opts)
    if type(type_name) ~= "string" or type_name == "" then
        return {}
    end

    local catalog = M.catalog()
    return metadata_stdlib.constants_by_type(catalog.version, type_name, opts)
end

function M.signature(path)
    local catalog = M.catalog()
    return metadata_stdlib.signature(catalog.version, path)
end

function M.shorthands()
    local catalog = M.catalog()
    if not catalog.shorthands then
        catalog.shorthands = shorthands_view(catalog.version)
    end
    return catalog.shorthands
end

function M.reset()
    cache = {
        catalog = nil,
    }
    generation = generation + 1
    symbol_metadata.reset()
    font_discovery.reset()
    metadata_artifacts.reset()
end

function M.generation()
    return generation
end

return M
