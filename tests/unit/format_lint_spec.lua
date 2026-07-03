local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()

local format_calls = 0
local lint_calls = 0
local original_notify = vim.notify

vim.notify = function() end

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("format-lint-output"),
    format = {
        provider = function(bufnr, state, opts)
            format_calls = format_calls + 1
            assert(
                vim.api.nvim_buf_is_valid(bufnr),
                "formatter should receive a valid buffer"
            )
            assert(state.root == root, "formatter should receive project state")
            assert(opts ~= nil, "formatter should receive options")
            return {
                ok = true,
                provider = "test-format",
                text = "= Main\n\nFormatted body\n",
            }
        end,
    },
    lint = {
        provider = function(bufnr, state, opts)
            lint_calls = lint_calls + 1
            assert(
                vim.api.nvim_buf_is_valid(bufnr),
                "linter should receive a valid buffer"
            )
            assert(state.root == root, "linter should receive project state")
            assert(opts ~= nil, "linter should receive options")
            return {
                ok = true,
                provider = "test-lint",
                output = "tests/fixtures/basic/main.typ:1:1: warning: lint message",
            }
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local bufnr = vim.api.nvim_get_current_buf()
local project = typst.project.set_main(main)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "= Main",
    "#let body=[unformatted]",
})

local format_result = typst.tools.format({ notify = false })
assert(format_result.ok, "format provider should succeed")
assert(format_result.changed, "format should report changed buffer text")
assert(format_result.provider == "test-format", "format should report provider")
assert(format_calls == 1, "format provider should be called once")
assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
        "= Main",
        "",
        "Formatted body",
    }),
    "format should replace the buffer with provider text"
)

vim.cmd("TypstFormat")
assert(format_calls == 2, ":TypstFormat should call the configured formatter")

local prose_paragraph =
    "This paragraph has *strong* and _emphasis_ markup that can be wrapped safely while keeping the words in their original order for prose editing."
local math_paragraph =
    "This paragraph has $ alpha + beta $ and should remain untouched because math markup is present."
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "= Main",
    "",
    prose_paragraph,
    "",
    "#let value = 1",
    "",
    math_paragraph,
})

local prose_result =
    typst.tools.format({ notify = false, provider = "prose", width = 44 })
assert(prose_result.ok, "prose formatter should succeed")
assert(prose_result.changed, "prose formatter should report changed text")
assert(
    prose_result.provider == "prose",
    "prose formatter should report provider"
)

local prose_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local code_index
for index, line in ipairs(prose_lines) do
    if line == "#let value = 1" then
        code_index = index
        break
    end
end
assert(code_index and code_index > 4, "prose paragraph should wrap before code")

local wrapped_prose = {}
for index = 3, code_index - 2 do
    assert(
        vim.fn.strdisplaywidth(prose_lines[index]) <= 44,
        "wrapped prose lines should respect configured width"
    )
    wrapped_prose[#wrapped_prose + 1] = prose_lines[index]
end
assert(
    table.concat(wrapped_prose, " ") == prose_paragraph,
    "prose wrapping should preserve paragraph text"
)
assert(
    prose_lines[code_index] == "#let value = 1",
    "prose formatter should leave code lines untouched"
)
assert(
    prose_lines[#prose_lines] == math_paragraph,
    "prose formatter should leave math paragraphs untouched"
)

local lint_result = typst.tools.lint({ notify = false })
assert(lint_result.ok, "lint provider should succeed")
assert(lint_result.provider == "test-lint", "lint should report provider")
assert(lint_result.diagnostics == 1, "lint should publish one diagnostic")
assert(lint_calls == 1, "lint provider should be called once")

local namespace = require("typst.diagnostics").namespace_for(project, "lint")
local published = vim.diagnostic.get(bufnr, { namespace = namespace })
assert(
    #published == 1,
    "lint should publish diagnostics to the typst.nvim namespace"
)
assert(
    published[1].message == "lint message",
    "lint diagnostic should use parsed message"
)

vim.fn.setqflist({}, "r", { title = "empty", items = {} })
vim.cmd("TypstLint!")
local quickfix = vim.fn.getqflist()
assert(#quickfix == 1, ":TypstLint! should populate quickfix")
assert(
    quickfix[1].text == "lint message",
    "quickfix should contain lint diagnostic"
)
assert(lint_calls == 2, ":TypstLint! should call the configured linter")
vim.cmd("cclose")
vim.api.nvim_set_current_buf(bufnr)

local original_get_clients = vim.lsp.get_clients
local tinymist_namespace = vim.lsp.diagnostic.get_namespace(91001)
local unrelated_namespace =
    vim.api.nvim_create_namespace("typst.nvim.test.unrelated")
vim.diagnostic.set(tinymist_namespace, bufnr, {
    {
        lnum = 0,
        col = 0,
        message = "tinymist diagnostic",
        severity = vim.diagnostic.severity.WARN,
    },
})
vim.diagnostic.set(unrelated_namespace, bufnr, {
    {
        lnum = 0,
        col = 0,
        message = "unrelated diagnostic",
        severity = vim.diagnostic.severity.ERROR,
    },
})
vim.lsp.get_clients = function()
    return {
        {
            id = 91001,
            name = "tinymist",
        },
    }
end

local tinymist_lint = typst.tools.lint({
    notify = false,
    provider = "tinymist",
    project = project,
})
assert(
    tinymist_lint.ok,
    tinymist_lint.message or "Tinymist lint should succeed when attached"
)
assert(
    tinymist_lint.diagnostics == 1,
    "Tinymist lint should only collect Tinymist diagnostics"
)
assert(
    tinymist_lint.by_buffer[bufnr][1].message == "tinymist diagnostic",
    "Tinymist lint should preserve Tinymist diagnostic details"
)

vim.lsp.get_clients = original_get_clients
vim.diagnostic.reset(tinymist_namespace, bufnr)
vim.diagnostic.reset(unrelated_namespace, bufnr)

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

local format_timeout_result = nil
local format_timeout = typst.tools.format({
    notify = false,
    provider = "command",
    command = vim.v.progpath,
    timeout_ms = 5,
}, function(result)
    format_timeout_result = result
end)
assert(format_timeout.pending, "format timeout run should be async")
assert(
    vim.wait(1000, function()
        return format_timeout_result ~= nil
    end, 10),
    "format timeout callback should run"
)
assert(
    format_timeout_result.reason == "timeout",
    "format command timeout should be classified as timeout"
)

local lint_timeout_result = nil
local lint_timeout = typst.tools.lint({
    notify = false,
    provider = "command",
    command = vim.v.progpath,
    timeout_ms = 5,
}, function(result)
    lint_timeout_result = result
end)
assert(lint_timeout.pending, "lint timeout run should be async")
assert(
    vim.wait(1000, function()
        return lint_timeout_result ~= nil
    end, 10),
    "lint timeout callback should run"
)
assert(
    lint_timeout_result.reason == "timeout",
    "lint command timeout should be classified as timeout"
)
assert(timeout_kills >= 4, "timed-out command providers should be terminated")

local pending_format = typst.tools.format({
    notify = false,
    provider = "command",
    command = vim.v.progpath,
    timeout_ms = 500,
})
assert(
    pending_format.pending,
    "format command provider should be async by default"
)
assert(
    type(pending_format.cancel) == "function",
    "async format command should be cancellable"
)
pending_format.cancel({ timeout_ms = 1, kill_timeout_ms = 1 })

local pending_lint = typst.tools.lint({
    notify = false,
    provider = "command",
    command = vim.v.progpath,
    timeout_ms = 500,
})
assert(pending_lint.pending, "lint command provider should be async by default")
assert(
    type(pending_lint.cancel) == "function",
    "async lint command should be cancellable"
)
pending_lint.cancel({ timeout_ms = 1, kill_timeout_ms = 1 })
assert(
    timeout_kills >= 4,
    "cancelling async command providers should signal their handles"
)
vim.system = original_system

vim.notify = original_notify
vim.cmd("qa!")
