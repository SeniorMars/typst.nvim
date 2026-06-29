local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local metadata = require("typst.metadata")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("metadata-output"),
})

local function item_name(item)
    if type(item) == "table" then
        return item.canonical
    end

    return item
end

local function contains(items, expected)
    for _, item in ipairs(items or {}) do
        if item_name(item) == expected then
            return true
        end
    end
    return false
end

local function find_param(params, name)
    for _, param in ipairs(params or {}) do
        if param.name == name then
            return param
        end
    end
end

local function contains_path(items, expected)
    for _, item in ipairs(items or {}) do
        if type(item) == "table" and item.path == expected then
            return true
        end
    end
    return false
end

local function find_variant(items, canonical)
    for _, item in ipairs(items or {}) do
        if type(item) == "table" and item.canonical == canonical then
            return item
        end
    end
end

local catalog = metadata.catalog()
local available_versions = metadata.available_versions()
assert(
    contains(available_versions, "0.14.2"),
    "metadata should bundle the Typst 0.14.2 snapshot"
)
assert(
    contains(available_versions, "0.15.0"),
    "metadata should bundle the Typst 0.15.0 snapshot"
)
assert(
    available_versions[#available_versions] == "0.15.0",
    "metadata versions should be semver-sorted"
)
assert(
    catalog.version == "0.15.0",
    "metadata should load the bundled Typst 0.15.0 snapshot"
)
assert(
    rawget(catalog, "stdlib") == nil,
    "stdlib metadata should be lazy-loaded"
)
assert(
    catalog.artifacts.symbols.count > 1000,
    "manifest should expose symbol counts without loading symbols"
)
assert(
    catalog.artifacts.stdlib_index.bytes < 200000,
    "stdlib index should stay compact"
)
assert(
    catalog.artifacts.signatures.bytes < 50000,
    "signature payload should stay compact"
)
assert(
    catalog.artifacts.signatures.schema == 2,
    "signature schema should expose value documentation"
)
assert(
    catalog.artifacts.signature_docs.bytes < 250000,
    "lazy signature docs payload should stay bounded"
)
assert(
    catalog.artifacts.signature_docs.schema == 1,
    "signature docs should use the expected schema"
)

local arrow =
    assert(catalog.symbols.arrow, "metadata should expose root symbols")
assert(
    arrow.glyph == "→",
    "root symbol glyph should come from Typst metadata"
)
assert(
    arrow.nvim_conceal_safe,
    "single-scalar symbol records should be safe for native conceal"
)
assert(
    vim.deep_equal(arrow.codepoints, { 0x2192 }),
    "symbol records should expose Unicode codepoints"
)
assert(arrow.scalar_count == 1, "symbol metrics should be derived at runtime")
assert(
    arrow.grapheme_count == 1,
    "symbol records should expose grapheme counts"
)
assert(arrow.display_width == 1, "symbol records should expose display width")
assert(
    arrow.variants[1].canonical,
    "symbol variants should be structured records"
)
assert(
    contains(arrow.variants, "arrow.r"),
    "root symbol variants should include dotted modifiers"
)
assert(
    contains(arrow.variants, "arrow.r.long"),
    "root symbol variants should include nested modifiers"
)
local arrow_r_long_variant = assert(
    find_variant(arrow.variants, "arrow.r.long"),
    "symbol variants should expose canonical nested variants"
)
assert(
    vim.deep_equal(arrow_r_long_variant.modifiers, { "r", "long" }),
    "symbol variants should expose Typst modifier sets"
)
assert(
    arrow_r_long_variant.glyph,
    "symbol variants should expose their rendered glyph"
)
assert(
    vim.deep_equal(
        arrow_r_long_variant.codepoints,
        { vim.fn.char2nr(arrow_r_long_variant.glyph) }
    ),
    "symbol variants should expose Unicode codepoints"
)
assert(
    arrow_r_long_variant.scalar_count == 1,
    "symbol variants should expose scalar counts"
)
assert(
    arrow_r_long_variant.grapheme_count == 1,
    "symbol variants should expose grapheme counts"
)
assert(
    arrow_r_long_variant.nvim_conceal_safe,
    "symbol variants should expose native conceal safety"
)
assert(
    vim.tbl_contains(metadata.symbol_variants("arrow"), "arrow.r.long"),
    "symbol variant API should expose prefix variants"
)
local variant_records = metadata.symbol_variant_records("arrow")
assert(
    find_variant(variant_records, "arrow.r.long"),
    "symbol variant record API should expose structured variants"
)
variant_records[1].canonical = "mutated"
assert(
    metadata.symbol_variant_records("arrow")[1].canonical ~= "mutated",
    "symbol variant record API should return mutation-safe copies"
)
assert(
    vim.tbl_contains(metadata.symbol_names(), "arrow.r"),
    "symbol name API should expose sorted canonical names"
)
local iter_symbol_name, iter_symbol_record = metadata.symbol_iter()()
assert(
    type(iter_symbol_name) == "string"
        and iter_symbol_record
        and iter_symbol_record.glyph,
    "symbol iterator should expose names and records without requiring a copied name array"
)
assert(
    vim.deep_equal(
        metadata.symbol_complete("arrow.r", 2),
        { "arrow.r", "arrow.r.bar" }
    ),
    "symbol completion should use sorted prefix ranges and limits"
)

local arrow_r = assert(
    catalog.symbols["arrow.r"],
    "metadata should expose dotted symbol variants"
)
assert(
    arrow_r.glyph == "→",
    "dotted symbol glyph should come from Typst metadata"
)
assert(
    arrow_r.symbol_id == "sym.arrow.r",
    "dotted symbol id should be sym-qualified"
)
assert(
    arrow_r.nvim_conceal_safe,
    "generated symbol records should expose Neovim conceal safety"
)
assert(
    contains(arrow_r.variants, "arrow.r.long"),
    "dotted symbol variants should include nested modifiers"
)

local reordered_arrow = assert(
    metadata.symbol("arrow.double.r"),
    "symbol lookup should normalize modifier order"
)
assert(
    reordered_arrow.symbol_id == "sym.arrow.r.double",
    "modifier-order lookup should return Typst's canonical symbol id"
)
assert(
    vim.tbl_contains(
        metadata.symbol_variants("arrow.double.r"),
        "arrow.r.double"
    ),
    "modifier-order variant lookup should use the canonical prefix"
)
local reordered_records = metadata.symbol_variant_records("arrow.double.r")
assert(
    reordered_records[1] and reordered_records[1].canonical == "arrow.r.double",
    "modifier-order variant records should expose canonical variants"
)

local sum =
    assert(catalog.symbols.sum, "metadata should include math-facing symbols")
assert(
    contains(sum.variants, "sum.integral"),
    "math-facing symbols should include generated variants"
)

local sum_integral = assert(
    catalog.symbols["sum.integral"],
    "metadata should expose generated math variants"
)
assert(
    sum_integral.nvim_conceal_safe,
    "generated symbol records should be marked safe for conceal"
)

local halo = assert(
    catalog.emojis["face.halo"],
    "metadata should expose generated emoji variants"
)
assert(halo.glyph == "😇", "emoji glyph should come from Typst metadata")
assert(
    halo.symbol_id == "emoji.face.halo",
    "emoji symbol id should be emoji-qualified"
)
assert(
    vim.deep_equal(halo.codepoints, { 0x1F607 }),
    "emoji records should expose Unicode codepoints"
)
assert(halo.grapheme_count == 1, "emoji records should expose grapheme counts")
assert(
    halo.nvim_conceal_safe,
    "single-scalar emoji records should be marked available for opt-in conceal"
)
assert(
    vim.tbl_contains(metadata.emoji_names(), "face.halo"),
    "emoji name API should expose generated emoji names"
)
local iter_emoji_name, iter_emoji_record = metadata.emoji_iter()()
assert(
    type(iter_emoji_name) == "string"
        and iter_emoji_record
        and iter_emoji_record.glyph,
    "emoji iterator should expose names and records without requiring a copied name array"
)
assert(
    vim.deep_equal(
        metadata.emoji_complete("face.h", 2),
        { "face.halo", "face.happy" }
    ),
    "emoji completion should use sorted prefix ranges and limits"
)

local stdlib = metadata.stdlib()
assert(
    stdlib == catalog.stdlib,
    "stdlib accessor should populate the lazy catalog field"
)
assert(
    stdlib.version == "0.15.0",
    "stdlib metadata should carry the Typst version"
)

local table_info =
    assert(stdlib.global.table, "stdlib metadata should include global table")
assert(table_info.kind == "element", "table should be classified as an element")
assert(table_info.category == "model", "table should preserve binding category")
assert(
    table_info.contexts[1] == "global",
    "table should record global availability"
)
assert(
    table_info.docs == nil,
    "core stdlib metadata should not bundle full prose docs"
)
assert(
    table_info.members.cell and table_info.members.cell.kind == "element",
    "table should expose nested members"
)

local columns = assert(
    find_param(table_info.parameters, "columns"),
    "table should expose the columns parameter"
)
assert(
    columns.named and not columns.required,
    "columns should include named/required metadata"
)
assert(columns.settable, "element fields should preserve settable metadata")
assert(
    columns.input.kind == "union",
    "parameter input should preserve CastInfo unions"
)
assert(
    columns.default and columns.default.repr == "()",
    "parameter defaults should use Typst repr"
)

local equation = assert(
    stdlib.math.equation,
    "stdlib metadata should include math-mode equation"
)
assert(
    equation.kind == "element",
    "math.equation should be classified as an element"
)
assert(equation.category == "math", "math.equation should preserve category")
assert(
    equation.contexts[1] == "math",
    "math.equation should record math availability"
)

local array_map = assert(
    metadata.stdlib_item("array.map"),
    "stdlib path index should include type methods"
)
assert(
    array_map.kind == "function",
    "array.map should be indexed as a function"
)
assert(
    find_param(array_map.parameters, "self"),
    "array.map should preserve self parameter metadata"
)

local table_signature = assert(
    metadata.signature("table"),
    "signature API should expose built-in signatures"
)
assert(
    find_param(table_signature.parameters, "columns"),
    "signature API should expose parameters"
)
assert(
    #metadata.stdlib_complete("table", "global") > 0,
    "stdlib completion API should search compact index"
)
local compact_table_complete = metadata.stdlib_complete("table", "global", {
    limit = 1,
    direct_children = true,
})
assert(
    #compact_table_complete == 1,
    "stdlib completion should honor the requested limit"
)
assert(
    compact_table_complete[1].path == "table",
    "stdlib completion should use prefix lower-bound results"
)
assert(
    compact_table_complete[1].parameters == nil,
    "stdlib completion should return compact summaries by default"
)
assert(
    not contains_path(
        metadata.stdlib_complete(
            "tabl",
            "global",
            { limit = 10, direct_children = true }
        ),
        "table.cell"
    ),
    "direct stdlib completion should skip nested descendants for parent prefixes"
)
assert(
    contains_path(
        metadata.stdlib_complete(
            "table.c",
            "global",
            { limit = 10, direct_children = true }
        ),
        "table.cell"
    ),
    "direct stdlib completion should include matching direct children"
)
local full_table_complete = metadata.stdlib_complete("table", "global", {
    limit = 1,
    direct_children = true,
    signatures = true,
})
assert(
    find_param(full_table_complete[1].parameters, "columns"),
    "stdlib completion should load signatures only when requested"
)
assert(
    metadata.stdlib_param_docs("table", "columns"):find("column sizes", 1, true),
    "lazy parameter docs should expose generated native parameter documentation"
)
assert(
    metadata.stdlib_param_docs("table", "does-not-exist") == nil,
    "unknown parameter docs should return nil"
)

local image_signature = assert(
    metadata.signature("image"),
    "signature API should expose image metadata"
)
local image_fit = assert(
    find_param(image_signature.parameters, "fit"),
    "image signature should expose fit parameter"
)
local cover_value = assert(
    image_fit.input.values and image_fit.input.values[1],
    "image fit should expose accepted values"
)
assert(
    cover_value.repr == '"cover"',
    "CastInfo value metadata should preserve Typst repr"
)
assert(
    cover_value.docs
        and cover_value.docs:find("completely cover the area", 1, true),
    "CastInfo value metadata should preserve Typst value documentation"
)

local direction_constants =
    metadata.stdlib_constants_by_type("direction", { context = "global" })
assert(
    contains_path(direction_constants, "rtl"),
    "metadata should expose generated direction constants by type"
)
local alignment_constants =
    metadata.stdlib_constants_by_type("alignment", { context = "global" })
assert(
    contains_path(alignment_constants, "center"),
    "metadata should expose generated alignment constants by type"
)
local first_direction = assert(
    direction_constants[1],
    "direction constant lookup should return records"
)
assert(
    first_direction.type == "direction",
    "constant lookup should preserve value types"
)
assert(
    first_direction.repr,
    "constant lookup should preserve Typst repr values"
)
direction_constants[1].path = "mutated"
assert(
    metadata.stdlib_constants_by_type("direction", { context = "global" })[1].path
        ~= "mutated",
    "constant lookup should return mutation-safe copies"
)
assert(
    #metadata.stdlib_constants_by_type("not-a-typst-type") == 0,
    "unknown constant types should return an empty list"
)

local shorthands = metadata.shorthands()
assert(
    shorthands.markup.source_to_glyph["..."] == "…",
    "markup shorthands should map source to glyph"
)
assert(
    shorthands.markup.glyph_to_source["…"] == "...",
    "markup shorthands should map glyph to source"
)
assert(
    shorthands.math.source_to_glyph["->"] == "→",
    "math shorthands should map arrows"
)

metadata.reset()
typst.setup({
    root = root,
    metadata_version = "0.15.0",
    output_dir = typst_test_cache_path("metadata-output"),
})
local pinned_catalog = metadata.catalog()
assert(
    pinned_catalog.version == "0.15.0",
    "explicit metadata_version should select bundled artifacts"
)
assert(
    pinned_catalog.requested_version == "0.15.0",
    "catalog should report the requested metadata version"
)
assert(
    not pinned_catalog.version_mismatch,
    "matching metadata_version should not report a mismatch"
)

metadata.reset()
typst.setup({
    root = root,
    metadata_version = "0.14.2",
    output_dir = typst_test_cache_path("metadata-output"),
})
local previous_catalog = metadata.catalog()
assert(
    previous_catalog.version == "0.14.2",
    "explicit metadata_version should select previous bundled artifacts"
)
assert(
    previous_catalog.requested_version == "0.14.2",
    "previous catalog should report the requested metadata version"
)
assert(
    not previous_catalog.version_mismatch,
    "previous bundled metadata_version should not report a mismatch"
)
assert(
    previous_catalog.artifacts.stdlib_index.count > 0,
    "previous manifest should expose stdlib metadata"
)
assert(
    metadata.stdlib().version == "0.14.2",
    "previous stdlib metadata should carry its Typst version"
)
assert(
    metadata.symbol("arrow.r"),
    "previous symbol metadata should be queryable"
)

metadata.reset()
typst.setup({
    root = root,
    metadata_version = "0.16.0",
    output_dir = typst_test_cache_path("metadata-output"),
})
local fallback_catalog = metadata.catalog()
assert(
    fallback_catalog.version == "0.15.0",
    "future metadata_version should fall back to newest bundled artifacts"
)
assert(
    fallback_catalog.requested_version == "0.16.0",
    "fallback catalog should report the requested version"
)
assert(
    fallback_catalog.version_mismatch,
    "fallback catalog should mark version mismatches"
)

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("metadata-output"),
})

catalog = nil
arrow = nil
arrow_r = nil
sum = nil
sum_integral = nil
halo = nil
stdlib = nil
table_info = nil
columns = nil
equation = nil
array_map = nil
table_signature = nil
shorthands = nil
collectgarbage("collect")
local memory_before_kib = collectgarbage("count")
metadata.reset()

local manifest_start = vim.uv.hrtime()
local compact_catalog = metadata.catalog()
local manifest_ms = (vim.uv.hrtime() - manifest_start) / 1000000
assert(
    manifest_ms < 250,
    ("metadata manifest load should stay cheap, got %.2fms"):format(manifest_ms)
)
assert(
    rawget(compact_catalog, "stdlib") == nil,
    "manifest load should not decode stdlib"
)

local symbol_start = vim.uv.hrtime()
assert(metadata.symbol("arrow.r"), "symbol lookup should decode symbols")
local symbol_ms = (vim.uv.hrtime() - symbol_start) / 1000000
assert(
    symbol_ms < 500,
    ("symbol metadata decode should stay cheap, got %.2fms"):format(symbol_ms)
)

local stdlib_start = vim.uv.hrtime()
assert(
    metadata.stdlib_item("table"),
    "stdlib lookup should decode compact index"
)
assert(
    metadata.signature("table"),
    "signature lookup should decode compact signatures"
)
local stdlib_ms = (vim.uv.hrtime() - stdlib_start) / 1000000
assert(
    stdlib_ms < 750,
    ("stdlib/signature decode should stay cheap, got %.2fms"):format(stdlib_ms)
)

collectgarbage("collect")
local memory_after_kib = collectgarbage("count")
assert(
    memory_after_kib - memory_before_kib < 4096,
    ("metadata decode should not grow Lua memory by more than 4MiB, got %.1fKiB"):format(
        memory_after_kib - memory_before_kib
    )
)
