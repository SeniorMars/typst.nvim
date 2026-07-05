local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local diagnostics = require("typst.diagnostics")
local lint = require("typst.lint")
local grammar = require("typst.syntax.grammar")

local lint_callbacks = {}
local grammar_callbacks = {}
local lint_results = {}
local grammar_results = {}

typst.reset()
typst.setup({
    root = root,
    lint = {
        provider = function(_, _, _, callback)
            lint_callbacks[#lint_callbacks + 1] = callback
            return nil
        end,
    },
    grammar = {
        provider = function(_, _, _, callback)
            grammar_callbacks[#grammar_callbacks + 1] = callback
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

grammar.check({ notify = false }, function(result)
    grammar_results[#grammar_results + 1] = result
end)
grammar.check({ notify = false }, function(result)
    grammar_results[#grammar_results + 1] = result
end)
grammar_callbacks[2]({
    provider = "grammar-test",
    output = ("%s:1:1: warning: newer grammar"):format(main),
})
grammar_callbacks[1]({
    provider = "grammar-test",
    output = ("%s:1:1: warning: older grammar"):format(main),
})
assert(
    grammar_results[1] and grammar_results[1].diagnostics == 1,
    "newer grammar result should publish diagnostics"
)
assert(
    grammar_results[2] and grammar_results[2].stale,
    "older grammar result should be stale"
)

local grammar_ns = diagnostics.namespace_for(project, "typst grammar")
local grammar_diagnostics = vim.diagnostic.get(0, { namespace = grammar_ns })
assert(
    #grammar_diagnostics == 1,
    "stale grammar should not clear newer diagnostics"
)
assert(
    grammar_diagnostics[1].message:find("newer grammar", 1, true),
    "stale grammar should not replace newer diagnostics"
)

vim.cmd("qa!")
