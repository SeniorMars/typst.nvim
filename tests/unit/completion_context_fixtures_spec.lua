local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local context = require("typst.completion.context")
local treesitter = require("typst.core.treesitter")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    '#image("fig',
    '#bibliography("refs.bib", style: "ie',
    "```py",
    "#rect(fill: fuch",
    '#set text(font: "Unit',
    "#rect(",
    "#rect(width: ",
    "$ alpha",
    "plain",
})

local original_find_containing = treesitter.find_containing
local ok, err = pcall(function()
    treesitter.find_containing = function(_, _, pos)
        return pos and pos[1] == 7 and {}
    end

    local callbacks = {
        parameter = function(_, row)
            return row == 5
        end,
        parameter_value = function(_, row)
            return row == 6
        end,
    }

    local cases = {
        { row = 0, col = 11, kind = "path", label = "path" },
        { row = 1, col = 36, kind = "csl_style", label = "CSL style" },
        { row = 2, col = 5, kind = "raw_language", label = "raw language" },
        { row = 3, col = 16, kind = "color", label = "color" },
        { row = 4, col = 21, kind = "font_family", label = "font" },
        { row = 5, col = 6, kind = "parameter", label = "parameter" },
        {
            row = 6,
            col = 13,
            kind = "parameter_value",
            label = "parameter value",
        },
        { row = 7, col = 7, kind = "math", label = "math" },
        { row = 8, col = 5, kind = "markup", label = "markup" },
    }

    for _, case in ipairs(cases) do
        context.clear_cache(bufnr)
        local kind = context.kind(bufnr, { case.row, case.col }, callbacks)
        assert(
            kind == case.kind,
            ("%s context classified as %s, expected %s"):format(
                case.label,
                tostring(kind),
                case.kind
            )
        )
    end
end)

treesitter.find_containing = original_find_containing
assert(ok, err)

vim.cmd("qa!")
