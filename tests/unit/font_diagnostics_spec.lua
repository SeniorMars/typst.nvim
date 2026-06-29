local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local fonts = require("typst.metadata.fonts")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    diagnostics = {
        font_scan_timeout_ms = 0,
    },
    completion = {
        font_families = {
            "Available Serif",
            "Available Mono",
        },
    },
})

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "typst"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '#set text(font: "Available Serif")',
    '#set text(font: "Missing Serif")',
    '#set text(font: ("Available Mono", "Missing Inline"))',
    '#set text(font: ("Missing Mixed", (name: "Available Serif", covers: "latin-in-cjk")))',
    "#set text(font: (",
    '  "Missing Mono",',
    '  (name: "Missing Dict", covers: "latin-in-cjk"),',
    "))",
    '// #set text(font: "Commented Missing")',
    '#let font = ("Not A Text Font")',
})

local result = typst.tools.font_diagnostics({ bufnr = buf, notify = false })
assert(result.ok, "font diagnostics should succeed")
assert(
    result.diagnostics == 5,
    ("expected 5 font diagnostics, got %s"):format(result.diagnostics)
)
assert(
    result.fonts == 2,
    "configured font families should seed the available font set"
)

local diagnostics = result.by_buffer[buf] or {}
local by_name = {}
for _, diagnostic in ipairs(diagnostics) do
    local name = diagnostic.message:match(": (.*)$")
    by_name[name] = diagnostic
end

for _, name in ipairs({
    "Missing Serif",
    "Missing Inline",
    "Missing Mixed",
    "Missing Mono",
    "Missing Dict",
}) do
    assert(by_name[name], ("missing font diagnostic for %s"):format(name))
end

assert(
    not by_name["Available Serif"],
    "available direct font should not be reported"
)
assert(
    not by_name["Available Mono"],
    "available list font should not be reported"
)
assert(
    not by_name["latin-in-cjk"],
    "coverage names should not be treated as font names"
)
assert(
    not by_name["Commented Missing"],
    "commented font references should be ignored"
)
assert(
    not by_name["Not A Text Font"],
    "plain variables named font should not be scanned"
)

local inline_line = vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
local inline_col = assert(
    inline_line:find("Missing Inline", 1, true),
    "inline font should exist"
) - 1
assert(
    by_name["Missing Inline"].col == inline_col,
    "inline list diagnostics should use buffer-relative columns"
)

local published = vim.diagnostic.get(buf, { namespace = fonts.namespace })
assert(
    #published == 5,
    "font diagnostics should publish to its diagnostic namespace"
)

typst.reset()
typst.setup({
    root = root,
    diagnostics = {
        fonts = false,
        font_scan_timeout_ms = 0,
    },
    completion = {
        font_families = {
            "Available Serif",
        },
    },
})

result = typst.tools.font_diagnostics({ bufnr = buf, notify = false })
assert(
    result.disabled == true,
    "disabled font diagnostics should report disabled state"
)
assert(
    #vim.diagnostic.get(buf, { namespace = fonts.namespace }) == 0,
    "disabled font diagnostics should clear diagnostics"
)

vim.cmd("qa!")
