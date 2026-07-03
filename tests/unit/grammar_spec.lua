local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()

local grammar_calls = 0
local original_notify = vim.notify

vim.notify = function() end

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("grammar-output"),
    grammar = {
        provider = function(bufnr, state, opts)
            grammar_calls = grammar_calls + 1
            assert(
                vim.api.nvim_buf_is_valid(bufnr),
                "grammar provider should receive a valid buffer"
            )
            assert(
                state.root == root,
                "grammar provider should receive project state"
            )
            assert(opts ~= nil, "grammar provider should receive options")
            return {
                ok = true,
                provider = "test-grammar",
                output = "tests/fixtures/basic/main.typ:1:1: warning: grammar message",
            }
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local bufnr = vim.api.nvim_get_current_buf()
local project = typst.project.set_main(main)

local result = typst.tools.grammar({ notify = false })
assert(result.ok, "grammar provider should succeed")
assert(result.provider == "test-grammar", "grammar should report provider")
assert(result.diagnostics == 1, "grammar should publish one diagnostic")
assert(grammar_calls == 1, "grammar provider should be called once")

local namespace =
    require("typst.diagnostics").namespace_for(project, "typst grammar")
local published = vim.diagnostic.get(bufnr, { namespace = namespace })
assert(
    #published == 1,
    "grammar should publish diagnostics to the typst.nvim namespace"
)
assert(
    published[1].message == "grammar message",
    "grammar diagnostic should use parsed message"
)
assert(
    published[1].source == "typst grammar",
    "grammar diagnostic should expose source"
)

vim.fn.setqflist({}, "r", { title = "empty", items = {} })
vim.cmd("TypstGrammar!")
local quickfix = vim.fn.getqflist()
assert(#quickfix == 1, ":TypstGrammar! should populate quickfix")
assert(
    quickfix[1].text == "grammar message",
    "quickfix should contain grammar diagnostic"
)
assert(
    grammar_calls == 2,
    ":TypstGrammar! should call the configured grammar provider"
)
vim.cmd("cclose")
vim.api.nvim_set_current_buf(bufnr)

local textidote_result = typst.tools.grammar({
    bufnr = bufnr,
    notify = false,
    provider = {
        name = "textidote",
        grammar = function()
            return {
                ok = true,
                provider = "textidote",
                output = "L2C3-L2C8: warning: repeated word",
            }
        end,
    },
})
assert(
    textidote_result.ok,
    "textidote parser should accept line/column output without a file"
)
assert(
    textidote_result.diagnostics == 1,
    "textidote parser should publish one diagnostic"
)
published = vim.diagnostic.get(bufnr, { namespace = namespace })
assert(
    #published == 1,
    "textidote parser should publish diagnostics to the current buffer"
)
assert(
    published[1].lnum == 1 and published[1].col == 0,
    "textidote L/C positions should be zero-based and clamped to line bytes"
)
assert(
    published[1].message == "repeated word",
    "textidote parser should extract the message"
)

local vlty_result = typst.tools.grammar({
    bufnr = bufnr,
    notify = false,
    provider = {
        name = "vlty",
        grammar = function()
            return {
                ok = true,
                provider = "vlty",
                output = vim.fn.json_encode({
                    [main] = {
                        {
                            Line = 3,
                            Span = { 5, 9 },
                            Check = "vlty.Passive",
                            Message = "Avoid passive voice",
                            Severity = "warning",
                        },
                    },
                }),
            }
        end,
    },
})
assert(vlty_result.ok, "vlty parser should accept JSON checker output")
assert(
    vlty_result.diagnostics == 1,
    "vlty parser should publish one diagnostic"
)
published = vim.diagnostic.get(bufnr, { namespace = namespace })
assert(
    #published == 1,
    "vlty parser should publish diagnostics to the fixture buffer"
)
assert(
    published[1].lnum == 2 and published[1].col == 4,
    "vlty JSON positions should be converted to zero-based diagnostics"
)
assert(
    published[1].message == "vlty.Passive: Avoid passive voice",
    "vlty parser should include rule names"
)

local original_system = vim.system
local timeout_kills = 0
vim.system = function()
    return {
        kill = function()
            timeout_kills = timeout_kills + 1
            return true
        end,
    }
end

local grammar_timeout_result = nil
local grammar_timeout = typst.tools.grammar({
    notify = false,
    provider = "command",
    command = vim.v.progpath,
    timeout_ms = 5,
}, function(result)
    grammar_timeout_result = result
end)
assert(grammar_timeout.pending, "grammar timeout run should be async")
assert(
    vim.wait(1000, function()
        return grammar_timeout_result ~= nil
    end, 10),
    "grammar timeout callback should run"
)
assert(
    grammar_timeout_result.reason == "timeout",
    "grammar command timeout should be classified as timeout"
)
assert(timeout_kills >= 2, "timed-out grammar command should be terminated")

local pending_grammar = typst.tools.grammar({
    notify = false,
    provider = "command",
    command = vim.v.progpath,
    timeout_ms = 500,
})
assert(
    pending_grammar.pending,
    "grammar command provider should be async by default"
)
assert(
    type(pending_grammar.cancel) == "function",
    "async grammar command should be cancellable"
)
pending_grammar.cancel({ timeout_ms = 1, kill_timeout_ms = 1 })
assert(
    timeout_kills >= 2,
    "cancelling async grammar command should signal its handle"
)
vim.system = original_system

vim.notify = original_notify
vim.cmd("qa!")
