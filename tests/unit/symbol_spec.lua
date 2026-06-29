local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local symbol_module = require("typst.metadata.symbol")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("symbol-output"),
})

local symbol = typst.symbol.info({ query = "arrow.r", open = false })
assert(
    symbol and symbol.kind == "symbol",
    "TypstSymbolInfo should resolve symbol metadata"
)
assert(symbol.glyph == "→", "symbol info should include the generated glyph")
assert(
    symbol.qualified_name == "sym.arrow.r",
    "symbol info should use sym-qualified names"
)
assert(
    symbol.item_id == "sym.arrow.r",
    "symbol info should expose the generated symbol id"
)

local emoji = typst.symbol.info({ query = "emoji.face.halo", open = false })
assert(
    emoji and emoji.kind == "emoji",
    "TypstSymbolInfo should resolve emoji metadata"
)
assert(emoji.glyph == "😇", "emoji info should include the generated glyph")
assert(
    emoji.qualified_name == "emoji.face.halo",
    "emoji info should use emoji-qualified names"
)

local fixture = root .. "/tests/fixtures/basic/conceal.typ"
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"
typst.project.attach(0)
local line = vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]
local start_col = assert(
    line:find("arrow.r", 1, true),
    "fixture should contain arrow.r"
) - 1
vim.api.nvim_win_set_cursor(0, { 3, start_col })
local cursor_symbol = typst.symbol.info({ open = false })
assert(
    cursor_symbol and cursor_symbol.id == "sym.arrow.r",
    "TypstSymbolInfo should resolve the symbol under cursor"
)

local results = typst.symbol.search("arrow", { limit = 10 })
assert(#results > 0, "symbol search should return metadata matches")
local symbol_completions = symbol_module.complete("sym.arrow.r")
assert(
    vim.tbl_contains(symbol_completions, "sym.arrow.r"),
    "symbol command completion should use symbol prefixes"
)
local emoji_completions = symbol_module.complete("emoji.face.h")
assert(
    vim.tbl_contains(emoji_completions, "emoji.face.halo"),
    "symbol command completion should use emoji prefixes"
)

local variants = typst.symbol.variants({ query = "arrow.r", open = false })
assert(
    vim.tbl_contains(variants, "arrow.r.long"),
    "TypstSymbolVariants should list generated variants"
)

local reordered_symbol =
    typst.symbol.info({ query = "arrow.double.r", open = false })
assert(
    reordered_symbol and reordered_symbol.id == "sym.arrow.r.double",
    "symbol info should normalize modifier order"
)
assert(
    reordered_symbol.name == "arrow.r.double",
    "symbol info should expose the canonical symbol name"
)

local opened = typst.symbol.info({ query = "arrow.r" })
assert(
    opened and opened.id == "sym.arrow.r",
    "TypstSymbolInfo should return the rendered result"
)
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(
    text:find("Typst Symbol Info", 1, true),
    "symbol info buffer should have a clear title"
)
assert(
    text:find("Glyph: →", 1, true),
    "symbol info buffer should include the glyph"
)
assert(
    text:find("Typst metadata version: 0.15.0", 1, true),
    "symbol info should report metadata version"
)
assert(
    text:find("Variants", 1, true),
    "symbol info buffer should include variants"
)
assert(
    text:find("arrow.r.long  [r, long]", 1, true),
    "symbol info buffer should show variant modifiers"
)

local rendered_variants = typst.symbol.variants({ query = "arrow.r" })
assert(#rendered_variants > 0, "rendered variant list should return variants")
local variant_text =
    table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(
    variant_text:find("Typst Symbol Variants", 1, true),
    "variant list should render into the symbol buffer"
)

vim.cmd("qa!")
