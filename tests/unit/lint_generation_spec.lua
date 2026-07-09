local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local lint = require("typst.lint")
local typst = require("typst")

local lint_callbacks = {}
local lint_results = {}

typst.reset()
typst.setup({
    root = root,
    lint = {
        provider = function(_, _, _, callback)
            lint_callbacks[#lint_callbacks + 1] = callback
            return nil
        end,
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
vim.bo.filetype = "typst"
local project = typst.project.attach(0)

lint.lint({ notify = false }, function(result)
    lint_results[#lint_results + 1] = result
end)
lint.lint({ notify = false }, function(result)
    lint_results[#lint_results + 1] = result
end)
lint_callbacks[2]({
    provider = "lint-test",
    output = ("%s:1:1: warning: newer lint"):format(main),
})
lint_callbacks[1]({
    provider = "lint-test",
    output = ("%s:1:1: warning: older lint"):format(main),
})
assert(
    lint_results[1] and lint_results[1].diagnostics == 1,
    "newer lint result should publish diagnostics"
)
assert(
    lint_results[2] and lint_results[2].stale,
    "older lint result should be stale"
)

local lint_ns = diagnostics.namespace_for(project, "lint")
local lint_diagnostics = vim.diagnostic.get(0, { namespace = lint_ns })
assert(#lint_diagnostics == 1, "stale lint should not clear newer diagnostics")
assert(
    lint_diagnostics[1].message:find("newer lint", 1, true),
    "stale lint should not replace newer diagnostics"
)

vim.cmd("qa!")
