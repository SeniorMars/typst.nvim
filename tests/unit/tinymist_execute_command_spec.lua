local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("tinymist-execute-command-output"),
})
local semantic = require("typst.integrations.semantic")
local tinymist = require("typst.integrations.tinymist")

local original_get_clients = vim.lsp.get_clients

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
vim.bo.filetype = "typst"
local bufnr = vim.api.nvim_get_current_buf()

---@type any
local exec_command = nil
---@type any
local exec_context = nil
---@type any
local exec_callback = nil
local exec_client = {
    id = 123,
    name = "tinymist",
    exec_cmd = function(_, command, context)
        exec_command = command
        exec_context = context
    end,
}

rawset(vim.lsp, "get_clients", function(opts)
    if opts and opts.bufnr == bufnr then
        return { exec_client }
    end
    return {}
end)

local ok, err = xpcall(function()
    local direct =
        tinymist.execute_command("tinymist.showTemplateGallery", nil, {
            bufnr = bufnr,
            callback = function(result)
                exec_callback = result
            end,
        })
    assert(direct.ok, "execute_command should run through client.exec_cmd")
    assert(
        direct.transport == "exec_cmd",
        "execute_command should report exec_cmd transport"
    )
    assert(
        exec_command.command == "tinymist.showTemplateGallery",
        "string commands should become LSP command objects"
    )
    assert(
        exec_command.title == "tinymist.showTemplateGallery",
        "string commands should get a stable default title"
    )
    assert(
        exec_context.bufnr == bufnr
            and exec_context.method == "workspace/executeCommand",
        "exec_cmd context should include buffer and source method"
    )
    assert(
        exec_callback and exec_callback.ok,
        "exec_cmd command result should reach callbacks"
    )

    local init = tinymist.execute_command({
        title = "Init template",
        command = "tinymist.initTemplate",
        arguments = { "old" },
    }, { "@preview/example:1.0.0" }, {
        bufnr = bufnr,
    })
    assert(init.ok, "command table should execute")
    assert(
        exec_command.command == "tinymist.initTemplate"
            and exec_command.arguments[1] == "@preview/example:1.0.0",
        "explicit arguments should override command table arguments"
    )

    ---@type any
    local request_params = nil
    local request_method = nil
    local request_bufnr = nil
    ---@type any
    local request_callback_result = nil
    local request_client = {
        id = 456,
        name = "tinymist",
        supports_method = function(_, method)
            return method == "workspace/executeCommand"
        end,
        request = function(_, method, params, callback, requested_bufnr)
            request_method = method
            request_params = params
            request_bufnr = requested_bufnr
            if callback then
                callback(nil, { accepted = true })
            end
            return true, 77
        end,
    }

    local pending = tinymist.execute_command(
        "tinymist.profileCurrentFile",
        { "--profile", "release" },
        {
            bufnr = bufnr,
            client = request_client,
            callback = function(result)
                request_callback_result = result
            end,
        }
    )
    assert(
        pending and pending.pending,
        "workspace/executeCommand with callback should return a pending handle"
    )
    assert(
        request_method == "workspace/executeCommand" and request_bufnr == bufnr,
        "workspace fallback should request executeCommand for the buffer"
    )
    assert(
        request_params.command == "tinymist.profileCurrentFile"
            and request_params.arguments[1] == "--profile",
        "workspace fallback should send ExecuteCommandParams"
    )
    assert(
        request_callback_result
            and request_callback_result.ok
            and request_callback_result.result.accepted,
        "workspace executeCommand result should be normalized"
    )

    request_params = nil
    local fire_and_forget = tinymist.execute_command(
        "tinymist.initTemplateInPlace",
        { "@preview/example:1.0.0" },
        {
            bufnr = bufnr,
            client = request_client,
        }
    )
    assert(
        fire_and_forget.ok
            and fire_and_forget.pending
            and fire_and_forget.transport == "workspace_request",
        "workspace executeCommand without callback should be fire-and-forget"
    )
    assert(
        request_params.command == "tinymist.initTemplateInPlace",
        "fire-and-forget command should still request executeCommand"
    )

    ---@type any
    local fallback_request_params = nil
    local exec_fallback_client = {
        id = 457,
        name = "tinymist",
        supports_method = function(_, method)
            return method == "workspace/executeCommand"
        end,
        exec_cmd = function()
            error("synthetic exec_cmd failure")
        end,
        request = function(_, method, params, callback, requested_bufnr)
            fallback_request_params = {
                method = method,
                params = params,
                bufnr = requested_bufnr,
            }
            if callback then
                callback(nil, { fallback = true })
            end
            return true, 78
        end,
    }
    local fallback_callback = nil
    local fallback = tinymist.execute_command("tinymist.exportPdf", { "pdf" }, {
        bufnr = bufnr,
        client = exec_fallback_client,
        callback = function(result)
            fallback_callback = result
        end,
    })
    assert(
        fallback and fallback.pending,
        "exec_cmd failure should fall back to workspace/executeCommand"
    )
    assert(
        fallback_request_params
            and fallback_request_params.method == "workspace/executeCommand"
            and fallback_request_params.params.command
                == "tinymist.exportPdf",
        "exec_cmd failure fallback should request executeCommand"
    )
    assert(
        fallback_callback
            and fallback_callback.ok
            and fallback_callback.result.fallback == true,
        "exec_cmd failure fallback should normalize callback result"
    )

    ---@type any
    local invalid_callback = nil
    ---@type any
    local invalid = tinymist.execute_command({}, nil, {
        bufnr = bufnr,
        callback = function(result)
            invalid_callback = result
        end,
    })
    assert(
        invalid.reason == "invalid_command"
            and invalid_callback.reason == "invalid_command",
        "invalid commands should fail before touching clients"
    )

    ---@type any
    local unsupported = tinymist.execute_command("tinymist.nope", nil, {
        bufnr = bufnr,
        client = {
            id = 458,
            name = "tinymist",
            supports_method = function()
                return false
            end,
        },
    })
    assert(
        unsupported.reason == "unsupported",
        "clients without exec_cmd or executeCommand support should fail explicitly"
    )

    rawset(vim.lsp, "get_clients", function()
        return {}
    end)
    ---@type any
    local no_client_callback = nil
    ---@type any
    local no_client =
        tinymist.execute_command("tinymist.showTemplateGallery", nil, {
            bufnr = bufnr,
            callback = function(result)
                no_client_callback = result
            end,
        })
    assert(
        no_client.reason == "no_client"
            and no_client_callback.reason == "no_client",
        "missing Tinymist client should fail explicitly"
    )

    local lens_request_count = 0
    local lens_execute_params = nil
    local lens_client = {
        id = 789,
        name = "tinymist",
        supports_method = function(_, method)
            return method == "textDocument/codeLens"
                or method == "workspace/executeCommand"
        end,
        request = function(_, method, params, callback, requested_bufnr)
            assert(
                requested_bufnr == bufnr,
                "code lens requests should stay buffer scoped"
            )
            if method == "textDocument/codeLens" then
                lens_request_count = lens_request_count + 1
                callback(nil, {
                    {
                        range = {
                            start = { line = 0, character = 0 },
                            ["end"] = { line = 0, character = 0 },
                        },
                        command = {
                            title = "Export PDF",
                            command = "tinymist.exportPdf",
                            arguments = { "pdf" },
                        },
                    },
                })
                return true, 88
            end
            if method == "workspace/executeCommand" then
                lens_execute_params = params
                return true, 89
            end
            error("unexpected method: " .. method)
        end,
    }

    rawset(vim.lsp, "get_clients", function(opts)
        if opts and opts.bufnr == bufnr then
            return { lens_client }
        end
        return {}
    end)

    local code_lens_result = nil
    local code_lens_pending = semantic.code_lens({
        root = root,
        main = main,
    }, {
        bufnr = bufnr,
        execute = 1,
        open = false,
        callback = function(result)
            code_lens_result = result
        end,
    })
    assert(
        code_lens_pending and code_lens_pending.pending,
        "semantic code_lens should request Tinymist asynchronously"
    )
    assert(
        code_lens_result and code_lens_result.ok and code_lens_result.count == 1,
        "semantic code_lens should still return the lens report payload"
    )
    assert(lens_request_count == 1, "code lens should be requested once")
    assert(
        lens_execute_params
            and lens_execute_params.command == "tinymist.exportPdf"
            and lens_execute_params.arguments[1] == "pdf",
        "semantic code_lens should execute returned Tinymist commands through the shared helper"
    )
end, debug.traceback)

vim.lsp.get_clients = original_get_clients

if not ok then
    error(err)
end

vim.cmd("qa!")
