local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local lint_results = require("typst.lint.results")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root = root,
    diagnostics = {
        enabled = true,
    },
    grammar = {
        provider = function()
            return {
                ok = true,
                provider = "test-grammar",
                output = ("%s/tests/fixtures/basic/main.typ:1:1: warning: grammar"):format(
                    root
                ),
            }
        end,
    },
    project = {
        import_scan = false,
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(vim.fn.fnameescape(main))
local project = typst.project.set_main(main)
local namespace = diagnostics.namespace_for(project)

diagnostics.publish(project, ("%s:1:1: error: first"):format(main))
assert(
    #vim.diagnostic.get(0, { namespace = namespace }) == 1,
    "initial diagnostics should publish"
)

local original_parse = diagnostics.parse
rawset(diagnostics, "parse", function()
    error("parser boom")
end)
local ok, published, err = xpcall(function()
    local result, parse_err =
        diagnostics.publish(project, ("%s:1:1: error: second"):format(main))
    return result, parse_err
end, debug.traceback)

diagnostics.parse = original_parse
if not ok then
    error(published)
end

assert(published == nil, "parse failure should not publish replacements")
assert(
    err and err.reason == "diagnostics_parse_failed",
    "parse failure should return a structured diagnostics error"
)
assert(
    #vim.diagnostic.get(0, { namespace = namespace }) == 1,
    "old diagnostics should survive parser failures"
)

local saw_log = false
for _, entry in ipairs(typst.ui.log()) do
    if
        entry.message == "diagnostic parse failed; keeping previous diagnostics"
    then
        saw_log = true
        break
    end
end
assert(saw_log, "parse failure should be logged")

rawset(diagnostics, "parse", function()
    return nil
end)
ok, published, err = xpcall(function()
    local result, parse_err =
        diagnostics.publish(project, ("%s:1:1: error: third"):format(main))
    return result, parse_err
end, debug.traceback)
diagnostics.parse = original_parse
if not ok then
    error(published)
end
assert(published == nil, "nil parser output should not publish replacements")
assert(
    err and err.reason == "diagnostics_parse_failed",
    "nil parser output should return a structured diagnostics error"
)
assert(
    #vim.diagnostic.get(0, { namespace = namespace }) == 1,
    "old diagnostics should survive nil parser output"
)

rawset(diagnostics, "parse", function()
    error("lint parser boom")
end)
local lint_ok, lint_result = xpcall(function()
    return lint_results.publish_output(
        project,
        ("%s:1:1: warning: lint"):format(main),
        { open = true },
        { provider = "test-lint" }
    )
end, debug.traceback)
diagnostics.parse = original_parse
if not lint_ok then
    error(lint_result)
end
assert(
    lint_result and lint_result.ok == false,
    "lint publish should return a structured failure on parser errors"
)
assert(
    lint_result.reason == "diagnostics_parse_failed",
    "lint publish should preserve diagnostics parse failure reason"
)
assert(
    lint_result.buffers == 0 and vim.tbl_isempty(lint_result.by_buffer),
    "lint publish failure should return empty diagnostic tables"
)

rawset(diagnostics, "parse", function()
    error("grammar parser boom")
end)
local grammar_ok, grammar_result = xpcall(function()
    return typst.tools.grammar({ notify = false })
end, debug.traceback)
diagnostics.parse = original_parse
if not grammar_ok then
    error(grammar_result)
end
assert(
    grammar_result and grammar_result.ok == false,
    "grammar publish should return a structured failure on parser errors"
)
assert(
    grammar_result.reason == "diagnostics_parse_failed",
    "grammar publish should preserve diagnostics parse failure reason"
)
assert(
    grammar_result.buffers == 0 and vim.tbl_isempty(grammar_result.by_buffer),
    "grammar publish failure should return empty diagnostic tables"
)

vim.cmd("qa!")
