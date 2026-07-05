local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("textobjects-output"),
})
local fixture = root .. "/tests/fixtures/basic/editing.typ"
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"
typst.project.attach(0)

local textobjects = require("typst.edit.textobjects")
local ts = require("typst.edit.treesitter")

local function text(kind, part, cursor)
    vim.api.nvim_win_set_cursor(0, cursor)
    local range = assert(
        textobjects.range(kind, part),
        ("missing %s %s range"):format(part, kind)
    )
    return ts.range_text(0, range)
end

local function line(n)
    return vim.api.nvim_buf_get_lines(0, n - 1, n, false)[1]
end

local function yanked(cursor, keys)
    vim.fn.setreg("0", "")
    vim.api.nvim_win_set_cursor(0, cursor)
    vim.cmd("silent normal " .. keys)
    return vim.fn.getreg("0")
end

assert(
    text("heading", "inner", { 1, 3 }) == "One #strong[Two]",
    "inner heading text object was wrong"
)
assert(
    text("heading", "outer", { 1, 3 }) == "= One #strong[Two]",
    "outer heading text object was wrong"
)

assert(
    text("equation", "inner", { 3, 6 }) == "x + y",
    "inner inline equation text object was wrong"
)
assert(
    text("equation", "outer", { 3, 6 }) == "$x + y$",
    "outer inline equation text object was wrong"
)
assert(
    text("equation", "inner", { 8, 3 }) == "a = b",
    "inner block equation text object was wrong"
)
assert(
    text("delimiter", "inner", { 3, 6 }) == "x + y",
    "inner math delimiter text object was wrong"
)
assert(
    text("delimiter", "outer", { 3, 6 }) == "$x + y$",
    "outer math delimiter text object was wrong"
)

local section = text("section", "inner", { 5, 3 })
assert(
    section:match("^%$"),
    "inner section should start at block equation content"
)
assert(
    section:match("a = b"),
    "inner section should include block equation content"
)

assert(
    text("content", "inner", { 13, 9 }) == "Hi",
    "inner content text object was wrong"
)
assert(
    text("content", "outer", { 13, 9 }) == "[Hi]",
    "outer content text object was wrong"
)
assert(
    text("delimiter", "inner", { 13, 9 }) == "Hi",
    "inner content delimiter text object was wrong"
)
assert(
    text("delimiter", "outer", { 13, 9 }) == "[Hi]",
    "outer content delimiter text object was wrong"
)
assert(
    text("delimiter", "inner", { 13, 16 }) == '[Hi], caption: [Cap], kind: "x"',
    "inner group delimiter text object was wrong"
)
assert(
    text("delimiter", "outer", { 13, 16 })
        == '([Hi], caption: [Cap], kind: "x")',
    "outer group delimiter text object was wrong"
)
assert(
    text("block", "inner", { 13, 9 }) == "Hi",
    "inner content block text object was wrong"
)
assert(
    text("block", "outer", { 13, 9 }) == "[Hi]",
    "outer content block text object was wrong"
)
assert(
    text("call", "outer", { 13, 2 })
        == 'figure([Hi], caption: [Cap], kind: "x")',
    "outer call text object was wrong"
)
assert(
    text("call", "inner", { 13, 2 }) == '[Hi], caption: [Cap], kind: "x"',
    "inner call text object was wrong"
)
assert(
    text("structural_block", "outer", { 13, 2 })
        == 'figure([Hi], caption: [Cap], kind: "x")',
    "outer structural block text object was wrong"
)
assert(
    text("structural_block", "inner", { 13, 2 })
        == '[Hi], caption: [Cap], kind: "x"',
    "inner structural block text object was wrong"
)
assert(
    text("call", "inner", { 14, 9 }) == "inside",
    "inner bracket-call text object was wrong"
)
assert(
    text("argument", "outer", { 13, 24 }) == "caption: [Cap]",
    "outer named argument text object was wrong"
)
assert(
    text("argument", "inner", { 13, 24 }) == "[Cap]",
    "inner named argument text object was wrong"
)
assert(
    text("argument", "inner", { 13, 37 }) == '"x"',
    "inner string argument text object was wrong"
)
assert(
    text("code_block", "inner", { 16, 2 }) == "#let z = 3",
    "inner code block text object was wrong"
)
assert(
    text("code_block", "outer", { 16, 2 }) == "```typst\n#let z = 3\n```",
    "outer code block text object was wrong"
)
assert(
    text("raw_block", "inner", { 16, 2 }) == "#let z = 3",
    "inner raw block text object was wrong"
)
assert(
    text("raw_block", "outer", { 16, 2 }) == "```typst\n#let z = 3\n```",
    "outer raw block text object was wrong"
)

assert(vim.fn.maparg("]]", "n") ~= "", "next heading mapping missing")
assert(
    vim.fn.maparg("ih", "o") ~= "",
    "inner heading text object mapping missing"
)
assert(
    vim.fn.maparg("id", "o") ~= "",
    "inner delimiter text object mapping missing"
)
assert(
    vim.fn.maparg("ic", "o") ~= "",
    "inner content text object mapping missing"
)
assert(
    vim.fn.maparg("ib", "o") ~= "",
    "inner block text object mapping missing"
)
assert(
    vim.fn.maparg("ie", "o") ~= "",
    "inner structural block text object mapping missing"
)
assert(vim.fn.maparg("if", "o") ~= "", "inner call text object mapping missing")
assert(
    vim.fn.maparg("ia", "o") ~= "",
    "inner argument text object mapping missing"
)
assert(
    vim.fn.maparg("ir", "o") ~= "",
    "inner raw block text object mapping missing"
)
assert(
    vim.fn.maparg("il", "o") ~= "",
    "inner label text object mapping missing"
)
assert(
    vim.fn.maparg("ii", "o") ~= "",
    "inner import text object mapping missing"
)

assert(
    yanked({ 1, 3 }, "yih") == "One #strong[Two]",
    "operator-pending inner heading mapping yanked wrong text"
)
assert(
    yanked({ 1, 3 }, "yah") == "= One #strong[Two]",
    "operator-pending outer heading mapping yanked wrong text"
)
assert(
    yanked({ 5, 3 }, "yiH") == "$\n  a = b\n$",
    "operator-pending inner section mapping yanked wrong text"
)
assert(
    yanked({ 5, 3 }, "yaH") == "== Two\n\n$\n  a = b\n$",
    "operator-pending outer section mapping yanked wrong text"
)
assert(
    yanked({ 3, 6 }, "yim") == "x + y",
    "operator-pending inner equation mapping yanked wrong text"
)
assert(
    yanked({ 3, 6 }, "yam") == "$x + y$",
    "operator-pending outer equation mapping yanked wrong text"
)
assert(
    yanked({ 13, 9 }, "yic") == "Hi",
    "operator-pending inner content mapping yanked wrong text"
)
assert(
    yanked({ 13, 9 }, "yac") == "[Hi]",
    "operator-pending outer content mapping yanked wrong text"
)
assert(
    yanked({ 13, 16 }, "yid") == '[Hi], caption: [Cap], kind: "x"',
    "operator-pending inner delimiter mapping yanked wrong text"
)
assert(
    yanked({ 13, 16 }, "yad") == '([Hi], caption: [Cap], kind: "x")',
    "operator-pending outer delimiter mapping yanked wrong text"
)
assert(
    yanked({ 13, 2 }, "yie") == '[Hi], caption: [Cap], kind: "x"',
    "operator-pending inner structural block mapping yanked wrong text"
)
assert(
    yanked({ 13, 2 }, "yae") == 'figure([Hi], caption: [Cap], kind: "x")',
    "operator-pending outer structural block mapping yanked wrong text"
)
assert(
    yanked({ 13, 2 }, "yif") == '[Hi], caption: [Cap], kind: "x"',
    "operator-pending inner call mapping yanked wrong text"
)
assert(
    yanked({ 13, 2 }, "yaf") == 'figure([Hi], caption: [Cap], kind: "x")',
    "operator-pending outer call mapping yanked wrong text"
)
assert(
    yanked({ 16, 2 }, "yiC") == "#let z = 3",
    "operator-pending inner code block mapping yanked wrong text"
)
assert(
    yanked({ 16, 2 }, "yaC") == "```typst\n#let z = 3\n```",
    "operator-pending outer code block mapping yanked wrong text"
)
assert(
    yanked({ 16, 2 }, "yir") == "#let z = 3",
    "operator-pending inner raw block mapping yanked wrong text"
)
assert(
    yanked({ 16, 2 }, "yar") == "```typst\n#let z = 3\n```",
    "operator-pending outer raw block mapping yanked wrong text"
)

vim.api.nvim_win_set_cursor(0, { 13, 24 })
vim.cmd("normal yia")
assert(
    vim.fn.getreg("0") == "[Cap]",
    "operator-pending inner argument mapping yanked wrong text"
)

vim.api.nvim_win_set_cursor(0, { 13, 24 })
assert(
    ts.range_text(
        0,
        assert(textobjects.range("argument", "outer", { count = 2 }))
    ) == 'caption: [Cap], kind: "x"',
    "counted outer argument text object range was wrong"
)
assert(
    not textobjects.range(
        "argument",
        "outer",
        { count = 3, lsp_fallback = false }
    ),
    "counted outer argument text object should reject counts past the final argument"
)

vim.fn.setreg("0", "")
vim.api.nvim_win_set_cursor(0, { 13, 24 })
vim.cmd("silent normal y2aa")
assert(
    vim.fn.getreg("0") == 'caption: [Cap], kind: "x"',
    ("operator-pending counted outer argument yanked wrong text: %q"):format(
        vim.fn.getreg("0")
    )
)

vim.fn.setreg("a", "")
vim.api.nvim_win_set_cursor(0, { 13, 24 })
vim.cmd([[normal "ayia]])
assert(
    vim.fn.getreg("a") == "[Cap]",
    "operator-pending inner argument should respect explicit registers"
)

vim.api.nvim_win_set_cursor(0, { 13, 24 })
vim.cmd("normal via")
vim.cmd("normal y")
assert(
    vim.fn.getreg("0") == "[Cap]",
    "visual-mode inner argument mapping selected wrong text"
)

vim.fn.setreg('"', "sentinel")
vim.api.nvim_win_set_cursor(0, { 13, 24 })
vim.cmd([[normal "_dia]])
assert(
    line(13) == '#figure([Hi], caption: , kind: "x")',
    "operator-pending inner argument delete changed wrong text"
)
assert(
    vim.fn.getreg('"') == "sentinel",
    "black-hole text object delete should not overwrite unnamed register"
)

local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(scratch)
vim.bo[scratch].filetype = "typst"
local scratch_lines = {
    '#import "lib.typ": helper, other as alias',
    "- item one",
    "See @sec:intro and <sec:intro>.",
    "#{ let x = 1 }",
    "#strong[block]",
    '#unicode("αβ", [γ])',
    "#content[]",
    "#empty()",
    "#broken([",
    "Unicode αβ item",
}
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, scratch_lines)

assert(
    text("import", "outer", { 1, 2 })
        == '#import "lib.typ": helper, other as alias',
    "outer import text object was wrong"
)
assert(
    text("import", "inner", { 1, 2 }) == '"lib.typ": helper, other as alias',
    "inner import text object was wrong"
)
assert(
    text("list_item", "outer", { 2, 3 }) == "- item one",
    "outer list item text object was wrong"
)
assert(
    text("list_item", "inner", { 2, 3 }) == "item one",
    "inner list item text object was wrong"
)
assert(
    text("label", "outer", { 3, 6 }) == "@sec:intro",
    "outer reference text object was wrong"
)
assert(
    text("label", "inner", { 3, 6 }) == "sec:intro",
    "inner reference text object was wrong"
)
assert(
    text("label", "outer", { 3, 22 }) == "<sec:intro>",
    "outer label text object was wrong"
)
assert(
    text("label", "inner", { 3, 22 }) == "sec:intro",
    "inner label text object was wrong"
)
assert(
    text("block", "outer", { 4, 4 }) == "{ let x = 1 }",
    "outer code block text object was wrong"
)
assert(
    text("block", "inner", { 4, 4 }) == "let x = 1",
    "inner code block text object was wrong"
)
assert(
    text("structural_block", "outer", { 5, 2 }) == "strong[block]",
    "outer call block alias was wrong"
)
assert(
    text("structural_block", "inner", { 5, 2 }) == "block",
    "inner call block alias was wrong"
)
assert(
    yanked({ 1, 2 }, "yii") == '"lib.typ": helper, other as alias',
    "operator-pending inner import mapping yanked wrong text"
)
assert(
    yanked({ 1, 2 }, "yai") == '#import "lib.typ": helper, other as alias',
    "operator-pending outer import mapping yanked wrong text"
)
assert(
    yanked({ 3, 6 }, "yil") == "sec:intro",
    "operator-pending inner label/reference mapping yanked wrong text"
)
assert(
    yanked({ 3, 6 }, "yal") == "@sec:intro",
    "operator-pending outer label/reference mapping yanked wrong text"
)

local unicode_string_col = assert(
    scratch_lines[6]:find("α", 1, true),
    "Unicode string fixture missing"
) - 1
local unicode_content_col = assert(
    scratch_lines[6]:find("γ", 1, true),
    "Unicode content fixture missing"
) - 1
assert(
    text("argument", "inner", { 6, unicode_string_col }) == '"αβ"',
    "inner argument text object should use byte columns for Unicode strings"
)
assert(
    text("argument", "inner", { 6, unicode_content_col }) == "γ",
    "inner argument text object should use byte columns for Unicode content"
)
assert(
    text("content", "outer", { 7, #scratch_lines[7] - 1 }) == "[]",
    "outer empty content text object should select delimiters"
)
assert(
    not textobjects.range(
        "content",
        "inner",
        { pos = { 7, #scratch_lines[7] - 1 }, lsp_fallback = false }
    ),
    "inner empty content text object should fail without selecting delimiters"
)
assert(
    not textobjects.range(
        "call",
        "inner",
        { pos = { 8, 2 }, lsp_fallback = false }
    ),
    "inner empty call text object should fail without selecting delimiters"
)
assert(
    not textobjects.range(
        "content",
        "outer",
        { pos = { 9, #scratch_lines[9] - 1 }, lsp_fallback = false }
    ),
    "incomplete content syntax should not produce a text object range"
)

local original_get_clients = vim.lsp.get_clients
local selection_request_count = 0
rawset(vim.lsp, "get_clients", function(opts)
    if not opts or opts.bufnr ~= scratch then
        return {}
    end
    return {
        {
            name = "tinymist",
            offset_encoding = "utf-16",
            supports_method = function(_, method)
                return method == "textDocument/selectionRange"
            end,
            request = function(_, method, params, callback, bufnr)
                selection_request_count = selection_request_count + 1
                assert(
                    method == "textDocument/selectionRange",
                    "fallback should request LSP selection ranges"
                )
                assert(
                    bufnr == scratch,
                    "fallback should request selection ranges for the current buffer"
                )
                if params.positions[1].line == 9 then
                    assert(
                        params.positions[1].character == 9,
                        "fallback should encode byte positions as UTF-16"
                    )
                    callback(nil, {
                        {
                            range = {
                                start = { line = 9, character = 8 },
                                ["end"] = { line = 9, character = 10 },
                            },
                        },
                    })
                    return true, selection_request_count
                end

                assert(
                    params.positions[1].line == 1,
                    "fallback should send the requested cursor line"
                )
                callback(nil, {
                    {
                        range = {
                            start = { line = 1, character = 2 },
                            ["end"] = { line = 1, character = 6 },
                        },
                        parent = {
                            range = {
                                start = { line = 1, character = 2 },
                                ["end"] = { line = 1, character = 10 },
                            },
                        },
                    },
                })
                return true, selection_request_count
            end,
        },
    }
end)

local function async_range(kind, part, opts)
    local resolved
    local pending = textobjects.range(
        kind,
        part,
        vim.tbl_extend("force", opts or {}, {
            callback = function(range)
                resolved = range
            end,
        })
    )
    assert(
        pending and pending.pending,
        "LSP text object fallback should be async"
    )
    return resolved
end

assert(
    ts.range_text(
        scratch,
        assert(async_range("call", "inner", { pos = { 1, 3 } }))
    ) == "item",
    "inner text object should fall back to Tinymist selectionRange when parsing does not match"
)
assert(
    ts.range_text(
        scratch,
        assert(async_range("call", "outer", { pos = { 1, 3 } }))
    ) == "item one",
    "outer text object should use the parent Tinymist selectionRange when parsing does not match"
)
assert(
    ts.range_text(
        scratch,
        assert(async_range("call", "inner", { pos = { 9, 10 } }))
    ) == "αβ",
    "Tinymist selectionRange fallback should decode UTF-16 ranges to byte columns"
)
assert(
    selection_request_count == 3,
    "selection-range fallback should be used for missing parser text objects"
)
vim.lsp.get_clients = original_get_clients

local current_win = vim.api.nvim_get_current_win()
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(other, 0, -1, false, {
    "= First",
    "= Other Buffer",
    "body",
})
vim.bo[other].filetype = "typst"
vim.cmd("botright split")
local other_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(other_win, other)
vim.api.nvim_win_set_cursor(other_win, { 2, 3 })
vim.api.nvim_set_current_win(current_win)
vim.api.nvim_win_set_cursor(current_win, { 10, 0 })
assert(
    ts.range_text(
        other,
        assert(textobjects.range("heading", "inner", {
            bufnr = other,
            lsp_fallback = false,
        }))
    ) == "Other Buffer",
    "noncurrent-buffer text object should use the target buffer cursor"
)

local hidden = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(hidden, 0, -1, false, {
    "= Hidden",
    "body",
})
vim.bo[hidden].filetype = "typst"
assert(textobjects.range("heading", "inner", {
    bufnr = hidden,
    lsp_fallback = false,
}) == nil, "hidden noncurrent-buffer text object should require opts.pos")
assert(
    ts.range_text(
        hidden,
        assert(textobjects.range("heading", "inner", {
            bufnr = hidden,
            pos = { 0, 1 },
            lsp_fallback = false,
        }))
    ) == "Hidden",
    "hidden noncurrent-buffer text object should accept explicit opts.pos"
)

vim.cmd("qa!")
