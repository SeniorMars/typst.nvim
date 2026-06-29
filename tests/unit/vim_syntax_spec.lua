local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

vim.cmd("syntax enable")
vim.cmd.edit(root .. "/tests/fixtures/basic/syntax.typ")
vim.bo.filetype = "typst"
vim.cmd("runtime! syntax/typst.vim")
vim.cmd("syntax sync fromstart")

assert(vim.b.current_syntax == "typst", "typst Vim syntax should load")

local function col_of(lnum, text)
    local col = vim.fn.getline(lnum):find(text, 1, true)
    assert(col, ("missing fixture text %q on line %d"):format(text, lnum))
    return col
end

local function stack_names(lnum, col)
    local names = {}
    for _, id in ipairs(vim.fn.synstack(lnum, col)) do
        names[#names + 1] = vim.fn.synIDattr(id, "name")
    end
    return names
end

local function has_group(lnum, col, group)
    for _, name in ipairs(stack_names(lnum, col)) do
        if name == group then
            return true
        end
    end
    return false
end

local function assert_group(lnum, text, group)
    local col = col_of(lnum, text)
    assert(
        has_group(lnum, col, group),
        ("expected %s at %d:%d for %q; stack=%s"):format(
            group,
            lnum,
            col,
            text,
            vim.inspect(stack_names(lnum, col))
        )
    )
end

assert_group(1, "=", "typstHeading")
assert_group(1, "<syntax-fixture>", "typstLabel")
assert_group(4, "TODO", "typstTodo")
assert_group(5, "NOTE", "typstTodo")
assert_group(8, "let", "typstStatement")
assert_group(8, '"info"', "typstString")
assert_group(12, "import", "typstStatement")
assert_group(12, '"index-lib.typ"', "typstString")
assert_group(14, "*strong text*", "typstStrong")
assert_group(14, "_emphasis_", "typstEmph")
assert_group(14, "`raw inline`", "typstRawSpan")
assert_group(14, "@syntax-fixture", "typstRef")
assert_group(15, "$", "typstMathDelimiter")
assert_group(15, "alpha", "typstMathSymbol")
assert_group(15, "arrow.r", "typstMathSymbol")
assert_group(15, "x_1", "typstMath")
assert_group(17, "strong", "typstFunction")
assert_group(19, "-", "typstListMarker")
assert_group(19, "<first-item>", "typstLabel")
assert_group(25, "figure", "typstFunction")
assert_group(28, '"demo"', "typstString")
assert_group(31, "typst", "typstRawBlock")
assert_group(32, "#let z = 3", "typstRawBlock")
assert_group(39, "sum", "typstMathSymbol")
assert_group(39, "1", "typstNumber")

vim.cmd("qa!")
