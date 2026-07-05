local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local formatting = require("typst.formatting")
local requests = require("typst.integrations.tinymist.requests")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("tinymist-format-async-output"),
})
local original_get_clients = vim.lsp.get_clients
local request_handlers = {}
local request_count = 0

local function flush_scheduled()
    vim.wait(20, function()
        return false
    end, 1, false)
end

local ok, err = xpcall(function()
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local bufnr = vim.api.nvim_get_current_buf()
    typst.project.set_main(main)

    local fake_client = {
        id = 99001,
        name = "tinymist",
        offset_encoding = "utf-16",
        supports_method = function(_, method)
            return method == "textDocument/formatting"
        end,
        request = function(_, method, params, handler, request_bufnr)
            assert(
                method == "textDocument/formatting",
                "Tinymist formatter should request document formatting"
            )
            assert(
                request_bufnr == bufnr,
                "Tinymist formatter should request the target buffer"
            )
            assert(
                params.textDocument.uri,
                "Tinymist formatter should send a textDocument"
            )
            request_count = request_count + 1
            request_handlers[request_count] = handler
            return true, request_count
        end,
    }

    rawset(vim.lsp, "get_clients", function(opts)
        assert(opts.bufnr == bufnr, "Tinymist lookup should be buffer-scoped")
        return { fake_client }
    end)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Original" })
    ---@type any
    local changed_result = nil
    ---@type any
    local pending = formatting.format({
        notify = false,
        provider = "tinymist",
    }, function(result)
        changed_result = result
    end)
    assert(pending.pending, "Tinymist formatting should run asynchronously")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "User edit" })
    request_handlers[1](nil, {
        {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = #"Original" },
            },
            newText = "Formatted",
        },
    })
    flush_scheduled()

    assert(
        changed_result and changed_result.reason == "buffer_changed",
        "Tinymist formatting should reject edited buffers"
    )
    assert(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "User edit",
        "Tinymist formatting should not overwrite user edits"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Original" })
    ---@type any
    local applied_result = nil
    ---@type any
    pending = formatting.format({
        notify = false,
        provider = "tinymist",
    }, function(result)
        applied_result = result
    end)
    assert(pending.pending, "second Tinymist format should return pending")
    request_handlers[2](nil, {
        {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = #"Original" },
            },
            newText = "Formatted",
        },
    })
    flush_scheduled()

    assert(
        applied_result and applied_result.ok and applied_result.changed,
        "Tinymist formatting should report applied edits"
    )
    assert(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "Formatted",
        "Tinymist formatting should apply fresh edits"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Base" })
    local older_result = nil
    local newer_result = nil
    formatting.format({
        notify = false,
        provider = "tinymist",
    }, function(result)
        older_result = result
    end)
    formatting.format({
        notify = false,
        provider = "tinymist",
    }, function(result)
        newer_result = result
    end)
    request_handlers[4](nil, {
        {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = #"Base" },
            },
            newText = "Newer",
        },
    })
    flush_scheduled()
    request_handlers[3](nil, {
        {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = #"Base" },
            },
            newText = "Older",
        },
    })
    flush_scheduled()

    assert(
        newer_result and newer_result.ok and newer_result.changed,
        "newer Tinymist format should apply"
    )
    assert(
        older_result == nil,
        "older Tinymist format callback should be dropped"
    )
    assert(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "Newer",
        "older Tinymist format should not replace newer output"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Direct" })
    local direct_older_result = nil
    local direct_newer_result = nil
    local direct_older_index = request_count + 1
    local direct_newer_index = request_count + 2

    requests.format(bufnr, { timeout_ms = 0 }, function(result)
        direct_older_result = result
    end)
    requests.format(bufnr, { timeout_ms = 0 }, function(result)
        direct_newer_result = result
    end)
    request_handlers[direct_older_index](nil, {
        {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = #"Direct" },
            },
            newText = "Older direct",
        },
    })
    flush_scheduled()

    assert(
        direct_older_result == nil,
        "older direct Tinymist format callback should be dropped"
    )
    assert(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "Direct",
        "older direct Tinymist format should not apply"
    )

    request_handlers[direct_newer_index](nil, {
        {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = #"Direct" },
            },
            newText = "Newer direct",
        },
    })
    flush_scheduled()

    assert(
        direct_newer_result
            and direct_newer_result.ok
            and direct_newer_result.changed,
        "newer direct Tinymist format should apply"
    )
    assert(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "Newer direct",
        "newer direct Tinymist format should win"
    )
end, debug.traceback)

vim.lsp.get_clients = original_get_clients

if not ok then
    error(err)
end

vim.cmd("qa!")
