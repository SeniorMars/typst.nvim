local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("tinymist-interactive-async-output"),
})
local tinymist = require("typst.integrations.tinymist")
local tinymist_async = require("typst.integrations.tinymist.async")
local semantic = require("typst.integrations.semantic")
local selection_lsp = require("typst.edit.textobject_lsp")

local original_get_clients = vim.lsp.get_clients
local handlers = {}
---@type any[]
local requests = {}
local request_id = 0
local command_executions = 0

local function flush_scheduled()
    vim.wait(20, function()
        return false
    end, 1, false)
end

local function workspace_edit(bufnr, replacement)
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

local ok, err = xpcall(function()
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    vim.bo.filetype = "typst"
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "old" })
    typst.project.set_main(main)

    local supported = {
        ["textDocument/rename"] = true,
        ["textDocument/codeAction"] = true,
        ["textDocument/references"] = true,
        ["textDocument/selectionRange"] = true,
    }

    local fake_client = {
        id = 88001,
        name = "tinymist",
        offset_encoding = "utf-16",
        supports_method = function(_, method)
            return supported[method] == true
        end,
        request = function(_, method, params, callback, request_bufnr)
            assert(
                request_bufnr == bufnr,
                "Tinymist async request should be buffer-scoped"
            )
            request_id = request_id + 1
            requests[request_id] = {
                method = method,
                params = params,
            }
            handlers[request_id] = callback
            return true, request_id
        end,
        cancel_request = function() end,
        exec_cmd = function(_, command)
            command_executions = command_executions + 1
            assert(
                command.command == "tinymist.testCommand",
                "Tinymist code action should execute the resolved command"
            )
        end,
    }

    rawset(vim.lsp, "get_clients", function(opts)
        if opts and opts.bufnr == bufnr then
            return { fake_client }
        end
        return {}
    end)

    local params_error_result = nil
    local params_error = tinymist_async.request(
        bufnr,
        "textDocument/rename",
        function()
            error("forced parameter failure")
        end,
        { client = fake_client },
        function(result)
            params_error_result = result
        end
    )
    assert(
        params_error and params_error.reason == "request_failed",
        "Tinymist parameter failures should return a request failure"
    )
    flush_scheduled()
    assert(
        params_error_result and params_error_result.reason == "request_failed",
        "Tinymist parameter failures should reach the async callback"
    )
    assert(
        request_id == 0,
        "Tinymist parameter failures should not call client.request"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ---@type any
    local rename_result = nil
    ---@type any
    local pending = tinymist.rename(bufnr, "new", {
        callback = function(result)
            rename_result = result
        end,
    })
    assert(pending.pending, "Tinymist rename should return a pending handle")
    assert(
        requests[1].method == "textDocument/rename",
        "Tinymist rename should use an async LSP request"
    )
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    handlers[1](nil, workspace_edit(bufnr, "new"))
    flush_scheduled()
    assert(
        rename_result and rename_result.reason == "cursor_moved",
        "Tinymist rename should reject cursor-stale responses"
    )
    assert(
        vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "old",
        "cursor-stale Tinymist rename should not apply edits"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ---@type any
    local action_result = nil
    ---@type any
    pending = tinymist.structural_action("heading_promote", {
        bufnr = bufnr,
        patterns = { "promote" },
        callback = function(result)
            action_result = result
        end,
    })
    assert(
        pending.pending,
        "Tinymist code action should return a pending handle"
    )
    assert(
        requests[2].method == "textDocument/codeAction",
        "Tinymist code action should use an async LSP request"
    )
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    handlers[2](nil, {
        {
            title = "Promote heading",
            edit = workspace_edit(bufnr, "= "),
        },
    })
    flush_scheduled()
    assert(
        action_result and action_result.reason == "cursor_moved",
        "Tinymist code action should reject cursor-stale responses"
    )
    assert(
        vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "old",
        "cursor-stale Tinymist code action should not apply edits"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ---@type any
    local references_result = nil
    ---@type any
    pending = semantic.references({
        root = root,
        main = main,
    }, {
        bufnr = bufnr,
        open = false,
        callback = function(result)
            references_result = result
        end,
    })
    assert(
        pending.pending,
        "Tinymist semantic references should return a pending handle"
    )
    assert(
        requests[3].method == "textDocument/references",
        "Tinymist references should use an async LSP request"
    )
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    handlers[3](nil, {
        {
            uri = vim.uri_from_bufnr(bufnr),
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 3 },
            },
        },
    })
    flush_scheduled()
    assert(
        references_result and references_result.reason == "cursor_moved",
        "Tinymist semantic references should reject cursor-stale responses"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ---@type any
    local selection_result = nil
    ---@type any
    pending = selection_lsp.selection_range(bufnr, "inner", {
        callback = function(result)
            selection_result = result
        end,
    })
    assert(
        pending.pending,
        "Tinymist selection range should return a pending handle"
    )
    assert(
        requests[4].method == "textDocument/selectionRange",
        "Tinymist selection range should use an async LSP request"
    )
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    handlers[4](nil, {
        {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 3 },
            },
        },
    })
    flush_scheduled()
    assert(
        selection_result and selection_result.reason == "cursor_moved",
        "Tinymist selection range should reject cursor-stale responses"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local older_rename = nil
    local newer_rename = nil
    tinymist.rename(bufnr, "older", {
        apply = false,
        callback = function(result)
            older_rename = result
        end,
    })
    local older_rename_id = request_id
    tinymist.rename(bufnr, "newer", {
        apply = false,
        callback = function(result)
            newer_rename = result
        end,
    })
    local newer_rename_id = request_id
    handlers[newer_rename_id](nil, workspace_edit(bufnr, "two"))
    flush_scheduled()
    handlers[older_rename_id](nil, workspace_edit(bufnr, "one"))
    flush_scheduled()
    assert(
        newer_rename and newer_rename.ok,
        "newer Tinymist rename generation should complete"
    )
    assert(
        older_rename and older_rename.reason == "stale_request",
        "older Tinymist rename generation should be rejected"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local older_action = nil
    local newer_action = nil
    tinymist.structural_action("heading_promote", {
        bufnr = bufnr,
        patterns = { "promote" },
        callback = function(result)
            older_action = result
        end,
    })
    local older_action_id = request_id
    tinymist.structural_action("heading_promote", {
        bufnr = bufnr,
        patterns = { "promote" },
        callback = function(result)
            newer_action = result
        end,
    })
    local newer_action_id = request_id
    handlers[newer_action_id](nil, {
        {
            title = "Promote heading",
            command = {
                title = "Promote heading",
                command = "tinymist.testCommand",
            },
        },
    })
    flush_scheduled()
    handlers[older_action_id](nil, {
        {
            title = "Promote heading",
            command = {
                title = "Promote heading",
                command = "tinymist.testCommand",
            },
        },
    })
    flush_scheduled()
    assert(
        newer_action and newer_action.ok,
        "newer Tinymist code action generation should complete"
    )
    assert(
        older_action and older_action.reason == "stale_request",
        "older Tinymist code action generation should be rejected"
    )
    assert(
        command_executions == 1,
        "stale Tinymist code action should not execute a command"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local older_references = nil
    local newer_references = nil
    semantic.references({
        root = root,
        main = main,
    }, {
        bufnr = bufnr,
        open = false,
        callback = function(result)
            older_references = result
        end,
    })
    local older_references_id = request_id
    semantic.references({
        root = root,
        main = main,
    }, {
        bufnr = bufnr,
        open = false,
        callback = function(result)
            newer_references = result
        end,
    })
    local newer_references_id = request_id
    local reference_locations = {
        {
            uri = vim.uri_from_bufnr(bufnr),
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 3 },
            },
        },
    }
    handlers[newer_references_id](nil, reference_locations)
    flush_scheduled()
    handlers[older_references_id](nil, reference_locations)
    flush_scheduled()
    assert(
        newer_references and newer_references.ok and newer_references.count == 1,
        "newer Tinymist semantic references generation should complete"
    )
    assert(
        older_references and older_references.reason == "stale_request",
        "older Tinymist semantic references generation should be rejected"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local older_selection = nil
    local newer_selection = nil
    selection_lsp.selection_range(bufnr, "inner", {
        callback = function(result)
            older_selection = result
        end,
    })
    local older_selection_id = request_id
    selection_lsp.selection_range(bufnr, "inner", {
        callback = function(result)
            newer_selection = result
        end,
    })
    local newer_selection_id = request_id
    local selection_ranges = {
        {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 3 },
            },
        },
    }
    handlers[newer_selection_id](nil, selection_ranges)
    flush_scheduled()
    handlers[older_selection_id](nil, selection_ranges)
    flush_scheduled()
    assert(
        newer_selection and newer_selection.ok and newer_selection.range,
        "newer Tinymist selection range generation should complete"
    )
    assert(
        older_selection and older_selection.reason == "stale_request",
        "older Tinymist selection range generation should be rejected"
    )

    local normalizer_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(normalizer_bufnr)
    vim.api.nvim_buf_set_lines(normalizer_bufnr, 0, -1, false, { "#let x = 1" })
    vim.bo[normalizer_bufnr].filetype = "typst"

    ---@type any
    local normalizer_result = nil
    local normalizer_client = {
        name = "tinymist-test",
        supports_method = function()
            return true
        end,
        request = function(_, _, _, callback)
            callback(nil, { unexpected = true })
            return true, 1
        end,
    }

    pending = tinymist_async.request(
        normalizer_bufnr,
        "workspace/symbol",
        function()
            return {}
        end,
        {
            client = normalizer_client,
            guard_cursor = false,
            guard_changedtick = false,
            timeout_ms = 1000,
        },
        function(result)
            normalizer_result = result
        end,
        function()
            error("normalizer exploded")
        end
    )

    assert(
        pending and pending.pending == true,
        "Tinymist async request should return a pending handle before response"
    )
    assert(
        vim.wait(1000, function()
            return normalizer_result ~= nil
        end, 5),
        "Tinymist async normalizer failure did not call back"
    )
    assert(
        normalizer_result.ok == false,
        "Tinymist async normalizer failure should become a failed result"
    )
    assert(
        normalizer_result.reason == "normalize_failed",
        "Tinymist async normalizer failure should be classified"
    )
    assert(
        normalizer_result.method == "workspace/symbol",
        "Tinymist async normalizer failure should retain method metadata"
    )
end, debug.traceback)

vim.lsp.get_clients = original_get_clients

if not ok then
    error(err)
end

vim.cmd("qa!")
