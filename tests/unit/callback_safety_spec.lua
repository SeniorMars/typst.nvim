local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local completion_lsp = require("typst.completion.lsp")
local follow = require("typst.navigation.follow")
local operation = require("typst.core.operation")
local process = require("typst.core.process")
local tinymist = require("typst.integrations.tinymist")

local original_tinymist_clients = tinymist.clients
local original_follow_resolve = follow.resolve
local original_system = vim.system

local ok, err = xpcall(function()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "alpha" })
    completion_lsp.reset()
    local lsp_callback = nil
    tinymist.clients = function(client_bufnr)
        assert(client_bufnr == bufnr, "completion should request target buffer")
        return {
            {
                id = 99,
                name = "tinymist",
                offset_encoding = "utf-16",
                supports_method = function()
                    return true
                end,
                request = function(_, method, _params, callback, request_bufnr)
                    assert(
                        method == "textDocument/completion",
                        "completion should issue Tinymist completion request"
                    )
                    assert(
                        request_bufnr == bufnr,
                        "completion should pass request buffer"
                    )
                    lsp_callback = callback
                    return true, 1
                end,
            },
        }
    end

    local good_waiter_called = false
    local request_opts = {
        bufnr = bufnr,
        position = { line = 0, character = 0 },
        completion_context = {},
        include_tinymist = true,
    }
    completion_lsp.items(
        vim.tbl_extend("force", request_opts, {
            completion_session = "throwing-waiter",
            on_tinymist_results = function()
                error("completion waiter exploded")
            end,
        }),
        "",
        "markup"
    )
    completion_lsp.items(
        vim.tbl_extend("force", request_opts, {
            completion_session = "good-waiter",
            on_tinymist_results = function(items)
                good_waiter_called = type(items) == "table" and #items == 1
            end,
        }),
        "",
        "markup"
    )
    assert(lsp_callback, "Tinymist completion callback should be captured")
    lsp_callback(nil, {
        items = {
            { label = "alpha" },
        },
    })
    assert(
        vim.wait(1000, function()
            return good_waiter_called
        end, 10, false),
        "throwing Tinymist completion waiter should not block later waiters"
    )

    local notify_ok = pcall(function()
        operation.notify_result(function(done)
            done({ ok = true })
            return { pending = true }
        end, {
            notify_result = function() end,
            callback = function()
                error("operation callback exploded")
            end,
        })
    end)
    assert(
        notify_ok,
        "operation.notify_result should isolate user callback errors"
    )

    local follow_callback_ran = false
    rawset(follow, "resolve", function()
        return { kind = "label", name = "target" }
    end)
    local follow_ok = pcall(function()
        follow.follow({
            open = false,
            callback = function()
                follow_callback_ran = true
                error("follow callback exploded")
            end,
        })
    end)
    assert(follow_ok, "navigation.follow should isolate user callback errors")
    assert(
        follow_callback_ran,
        "navigation.follow should still invoke callback"
    )

    local process_exit_called = false
    rawset(vim, "system", function(_command, _opts, on_exit)
        vim.schedule(function()
            on_exit({ code = 0, stdout = "", stderr = "" })
        end)
        return {
            is_closing = function()
                return true
            end,
            kill = function()
                return true
            end,
            wait = function()
                return { code = 0, stdout = "", stderr = "" }
            end,
        }
    end)
    process.spawn({ "fake" }, {}, {
        on_exit = function()
            process_exit_called = true
            error("process exit exploded")
        end,
    })
    assert(
        vim.wait(1000, function()
            return process_exit_called
        end, 10, false),
        "process exit callback should run"
    )
end, debug.traceback)

tinymist.clients = original_tinymist_clients
follow.resolve = original_follow_resolve
vim.system = original_system
completion_lsp.reset()

if not ok then
    error(err)
end

vim.cmd("qa!")
