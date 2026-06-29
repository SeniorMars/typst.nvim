local root = vim.fn.getcwd()
local content =
    table.concat(vim.fn.readfile(root .. "/docs/vimtex-parity.md"), "\n")
local help = table.concat(vim.fn.readfile(root .. "/doc/typst.txt"), "\n")
local api = table.concat(vim.fn.readfile(root .. "/API.md"), "\n")
local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
local public_docs = table.concat({ help, api, readme }, "\n")

assert(
    content:find("# VimTeX Parity Matrix", 1, true),
    "parity document heading missing"
)

for _, text in ipairs({
    ":TypstDoc",
    "TypstDocSymbol",
    "TypstDocSearch",
    "TypstDocPackage",
    "TypstDocSource",
    "TypstDocOnline",
    "docs.provider_chain",
}) do
    assert(
        not public_docs:find(text, 1, true),
        "public docs should not advertise removed TypstDoc surface: " .. text
    )
end

for _, text in ipairs({
    "Project Documentation",
    "PROJECT DOCUMENTATION",
}) do
    assert(
        not help:find(text, 1, true),
        "help should not use docs-subsystem wording: " .. text
    )
end

local classifications = {
    DIRECT = true,
    REINTERPRETED = true,
    DELEGATED = true,
    ["NOT APPLICABLE"] = true,
}

local statuses = {
    Implemented = true,
    Partial = true,
    Planned = true,
    Delegated = true,
    ["N/A"] = true,
}

local entries = {}
for line in content:gmatch("[^\n]+") do
    if line:find("| `|vimtex-", 1, true) == 1 then
        local cells = vim.split(line, " | ", { plain = true })
        local tag = cells[1] and cells[1]:match("vimtex[%w%._%-]+")
        local section = cells[2] and vim.trim(cells[2])
        local classification = cells[3] and vim.trim(cells[3])
        local equivalent = cells[4] and vim.trim(cells[4])
        local status = cells[5] and vim.trim(cells[5]:gsub("|%s*$", ""))

        assert(tag, "parity row missing VimTeX tag: " .. line)
        assert(section and section ~= "", "parity row missing section: " .. tag)
        assert(
            classifications[classification],
            ("invalid parity classification for %s: %s"):format(
                tag,
                tostring(classification)
            )
        )
        assert(
            equivalent and equivalent ~= "",
            "parity row missing typst.nvim equivalent: " .. tag
        )
        assert(
            statuses[status],
            ("invalid parity status for %s: %s"):format(tag, tostring(status))
        )

        entries[tag] = {
            classification = classification,
            section = section,
            status = status,
        }
    end
end

assert(vim.tbl_count(entries) >= 40, "parity table should not be truncated")

local required_areas = {
    project = "vimtex-multi-file",
    commands = "vimtex-commands",
    mappings = "vimtex-mappings",
    completion = "vimtex-completion",
    citations = "vimtex-complete-cites",
    folds = "vimtex-folding",
    syntax = "vimtex-syntax",
    conceal = "vimtex-syntax-conceal",
    navigation = "vimtex-navigation",
    toc = "vimtex-toc",
    compiler = "vimtex-compiler",
    viewer = "vimtex-view",
    source_sync = "vimtex-synctex-inverse-search",
    context_citations = "vimtex-context-citation",
    api = "vimtex-code-api",
}

for area, tag in pairs(required_areas) do
    assert(entries[tag], ("parity table missing %s area: %s"):format(area, tag))
end

for _, tag in ipairs({
    "vimtex-multi-file",
    "vimtex-commands",
    "vimtex-mappings",
    "vimtex-complete-cites",
    "vimtex-folding",
    "vimtex-includeexpr",
    "vimtex-context-citation",
    "vimtex-code-api",
}) do
    assert(
        entries[tag].status == "Implemented",
        "core parity row should be implemented: " .. tag
    )
end

assert(
    entries["vimtex-complete-glossary"].status == "Partial",
    "glossary completion parity should remain explicit partial coverage"
)
assert(
    entries["vimtex-compiler-arara"].status == "Implemented",
    "task/generic compiler parity should replace arara"
)

vim.cmd("qa!")
