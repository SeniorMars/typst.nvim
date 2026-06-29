local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("tinymist-actions-output"),
})

local fixture = root .. "/tests/fixtures/basic/editing.typ"
vim.cmd.edit(fixture)
vim.bo.filetype = "typst"
typst.project.attach(0)

local tinymist = require("typst.integrations.tinymist")
local original_get_clients = vim.lsp.get_clients
local original_notify = vim.notify
local bufnr = vim.api.nvim_get_current_buf()
local command_executed = nil
local requested_params = nil
local function run_action(name, opts)
    local action_result
    opts = vim.tbl_extend("force", opts or {}, {
        callback = function(result)
            action_result = result
        end,
    })
    local pending = tinymist.structural_action(name, opts)
    assert(
        pending == nil or pending.pending or pending.ok ~= nil,
        "structural action should return a pending/result value"
    )
    return action_result or pending
end

vim.notify = function() end

local fake_client = {
    id = 42,
    name = "tinymist",
    offset_encoding = "utf-16",
    rpc = {
        is_closing = function()
            return true
        end,
    },
}

function fake_client:stop() end

function fake_client:exec_cmd(command)
    command_executed = command.command
end

vim.lsp.get_clients = function(opts)
    if opts and opts.bufnr and opts.bufnr ~= bufnr then
        return {}
    end
    return { fake_client }
end

vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "== One #strong[Two]" })

local function workspace_edit(replacement)
    return {
        changes = {
            [vim.uri_from_bufnr(bufnr)] = {
                {
                    range = {
                        start = { line = 0, character = 0 },
                        ["end"] = { line = 0, character = 3 },
                    },
                    newText = replacement,
                },
            },
        },
    }
end

fake_client.request = function(_, method, params, callback)
    assert(
        method == "textDocument/codeAction",
        "unexpected Tinymist method: " .. method
    )
    requested_params = params
    callback(nil, {
        {
            title = "Promote heading",
            edit = workspace_edit("= "),
        },
    })
    return true, 1
end

vim.api.nvim_win_set_cursor(0, { 1, 1 })
local direct_result =
    tinymist.structural_action("heading_promote", { bufnr = bufnr })
assert(
    not direct_result.ok and direct_result.reason == "async_required",
    "direct Tinymist structural action should require a callback"
)
local result = run_action("heading_promote", { bufnr = bufnr })
assert(result.ok, "promote heading action was not applied")
assert(
    vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "= One #strong[Two]",
    "workspace edit was not applied"
)
assert(
    requested_params.context.triggerKind
        == vim.lsp.protocol.CodeActionTriggerKind.Invoked,
    "trigger kind missing"
)

fake_client.request = function(_, method, _, callback)
    assert(
        method == "textDocument/codeAction",
        "unexpected Tinymist method: " .. method
    )
    callback(nil, {
        {
            title = "Demote heading",
            command = {
                title = "Demote heading",
                command = "tinymist.demoteHeading",
            },
        },
    })
    return true, 2
end

result = run_action("heading_demote", { bufnr = bufnr })
assert(result.ok, "demote heading command action was not applied")
assert(
    command_executed == "tinymist.demoteHeading",
    "Tinymist command was not executed"
)

fake_client.request = function(_, _, _, callback)
    callback(nil, {
        {
            title = "Unrelated action",
        },
    })
    return true, 3
end

result = run_action("equation_block", { bufnr = bufnr })
assert(not result.ok, "unmatched action should fail")
assert(result.reason == "no_action", "unmatched action should report no_action")

local typst_result = typst.edit.convert_equation("inline", { bufnr = bufnr })
assert(
    not typst_result.ok and typst_result.reason == "no_equation",
    "main module should fall back to local equation conversion when Tinymist has no action"
)

local hidden_bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[hidden_bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(hidden_bufnr, 0, -1, false, { "== Hidden" })
local hidden_requests = 0
vim.lsp.get_clients = function(opts)
    if opts and opts.bufnr == hidden_bufnr then
        return { fake_client }
    end
    if opts and opts.bufnr and opts.bufnr ~= bufnr then
        return {}
    end
    return { fake_client }
end
fake_client.request = function(_, _, _, callback)
    hidden_requests = hidden_requests + 1
    callback(nil, {
        {
            title = "Promote heading",
            command = {
                title = "Promote heading",
                command = "tinymist.promoteHeading",
            },
        },
    })
    return true, 4
end
local hidden_without_range =
    run_action("heading_promote", { bufnr = hidden_bufnr })
assert(
    not hidden_without_range.ok
        and hidden_without_range.reason == "missing_position",
    "hidden noncurrent buffer action without range should fail closed"
)
assert(
    hidden_requests == 0,
    "hidden noncurrent buffer action should not borrow the current cursor"
)
local hidden_with_range = run_action("heading_promote", {
    bufnr = hidden_bufnr,
    range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 0, character = 0 },
    },
})
assert(
    hidden_with_range.ok,
    "hidden noncurrent buffer action should accept an explicit range"
)
assert(hidden_requests == 1, "explicit hidden-buffer range should request LSP")

vim.lsp.get_clients = original_get_clients
vim.notify = original_notify

vim.cmd("qa!")
