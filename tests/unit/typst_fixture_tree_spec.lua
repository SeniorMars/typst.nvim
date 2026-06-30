local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local fixture_root = root .. "/tests/fixtures/typst"

local required = {
    "single/main.typ",
    "project/.typstmain",
    "project/main.typ",
    "project/chapter.typ",
    "project/assets/image.svg",
    "project/bib/references.bib",
    "project/bib/refs.yml",
    "project/unicode/α β.typ",
    "project/raw-code.typ",
    "project/math.typ",
    "project/broken.typ",
    "large/main.typ",
}

for _, relative in ipairs(required) do
    local path = fixture_root .. "/" .. relative
    assert(vim.fn.filereadable(path) == 1, "missing fixture " .. relative)
end

local chapters =
    vim.fn.glob(fixture_root .. "/large/chapters/*.typ", false, true)
assert(
    #chapters >= 20,
    "large fixture should include enough chapters for traversal tests"
)

local main =
    table.concat(vim.fn.readfile(fixture_root .. "/project/main.typ"), "\n")
for _, needle in ipairs({
    "chapter.typ",
    "bib/references.bib",
    "assets/image.svg",
    "unicode/α β.typ",
}) do
    assert(
        main:find(needle, 1, true),
        "project fixture main should reference " .. needle
    )
end

vim.cmd("qa!")
