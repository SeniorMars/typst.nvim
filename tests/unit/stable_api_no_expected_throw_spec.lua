local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local function call(label, fn)
    local ok, first, second, third = pcall(fn)
    assert(ok, label .. " should not throw: " .. tostring(first))
    return first, second, third
end

typst.reset({ force = true })
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
    root_markers = {},
})

vim.cmd.enew()
local dashboard = vim.api.nvim_get_current_buf()
vim.bo[dashboard].filetype = "markdown"
vim.api.nvim_buf_set_lines(dashboard, 0, -1, false, { "# dashboard" })

for _, case in ipairs({
    {
        label = "compiler.compile",
        fn = function()
            return typst.compiler.compile({ bufnr = dashboard, notify = false })
        end,
    },
    {
        label = "compiler.watch",
        fn = function()
            return typst.compiler.watch({ bufnr = dashboard, notify = false })
        end,
    },
    {
        label = "compiler.stop",
        fn = function()
            return typst.compiler.stop({ bufnr = dashboard, notify = false })
        end,
    },
    {
        label = "compiler.status",
        fn = function()
            return typst.compiler.status({ bufnr = dashboard, notify = false })
        end,
    },
    {
        label = "compiler.output",
        fn = function()
            return typst.compiler.output({ bufnr = dashboard, notify = false })
        end,
    },
    {
        label = "compiler.current_output",
        fn = function()
            return typst.compiler.current_output({
                bufnr = dashboard,
                notify = false,
            })
        end,
    },
    {
        label = "viewer.view",
        fn = function()
            return typst.viewer.view({ bufnr = dashboard, notify = false })
        end,
    },
    {
        label = "viewer.view_forward",
        fn = function()
            return typst.viewer.view_forward({
                bufnr = dashboard,
                notify = false,
            })
        end,
    },
}) do
    local value, err = call(case.label, case.fn)
    assert(value == nil, case.label .. " should not return a value")
    assert(
        type(err) == "table" and err.reason == "no_project",
        case.label .. " should return structured no_project"
    )
end

local fixture = typst_test_cache_path("stable-api-no-expected-throw")
vim.fn.delete(fixture, "rf")
vim.fn.mkdir(fixture, "p")
local main = fixture .. "/main.typ"
vim.fn.writefile({ "= Main" }, main)
vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"

local missing_output = call("viewer.view missing output", function()
    return typst.viewer.view({ notify = false })
end)
assert(
    type(missing_output) == "table"
        and missing_output.ok == false
        and missing_output.reason == "missing_output",
    "viewer.view should return structured missing_output"
)

local missing_forward_output = call(
    "viewer.view_forward missing output",
    function()
        return typst.viewer.view_forward({ notify = false })
    end
)
assert(
    type(missing_forward_output) == "table"
        and missing_forward_output.ok == false
        and missing_forward_output.reason == "missing_output",
    "viewer.view_forward should return structured missing_output"
)

local inverse, inverse_err = call(
    "viewer.view_inverse unknown source",
    function()
        return typst.viewer.view_inverse({
            path = fixture .. "/missing.typ",
            notify = false,
        })
    end
)
assert(inverse == nil, "unknown inverse source should not return a location")
assert(
    type(inverse_err) == "table"
        and (
            inverse_err.reason == "source_path_not_in_project"
            or inverse_err.reason == "no_project"
        ),
    "viewer.view_inverse should fail structurally for unknown sources"
)

vim.cmd("qa!")
