local async = require("typst.core.async")
local lsp_request = require("typst.core.lsp_request")
local clients = require("typst.integrations.tinymist.clients")
local log = require("typst.core.log")
local request_async = require("typst.integrations.tinymist.async")

local M = {}

local METHOD = "workspace/executeCommand"

local function request_project(bufnr, opts)
    return type(opts.project) == "table" and opts.project
        or clients.project_for_buffer(bufnr)
end

local function protected_callback(callback, result)
    if type(callback) ~= "function" then
        return
    end

    local ok, err = pcall(callback, result)
    if not ok then
        log.add("error", "Tinymist command callback failed", {
            error = err,
        })
    end
end

local function immediate(callback, result)
    async.schedule(function()
        protected_callback(callback, result)
    end)
    return result
end

local function normalize_command(command, arguments, opts)
    opts = opts or {}
    local command_object
    if type(command) == "string" then
        if command == "" then
            return nil, nil, "invalid_command"
        end
        command_object = {
            title = opts.title or command,
            command = command,
        }
    elseif type(command) == "table" then
        if type(command.command) ~= "string" or command.command == "" then
            return nil, nil, "invalid_command"
        end
        command_object = vim.deepcopy(command)
    else
        return nil, nil, "invalid_command"
    end

    if arguments ~= nil then
        command_object.arguments = arguments
    end

    return command_object,
        {
            command = command_object.command,
            arguments = command_object.arguments,
        }
end

local function command_clients(bufnr, opts)
    local selected = clients.select_client({
        bufnr = bufnr,
        client = opts.client,
        project = request_project(bufnr, opts),
        method = METHOD,
        request = "async",
        allow_exec_cmd = true,
    })
    if not selected.ok then
        return {}, selected
    end
    return selected.clients or { selected.client }, selected
end

local function success_result(client, command_object, result, extra)
    return vim.tbl_extend("force", {
        ok = true,
        provider = "tinymist",
        client = client.name,
        method = METHOD,
        command = command_object.command,
        arguments = command_object.arguments,
        result = result,
    }, extra or {})
end

local function failure(reason, message, command_object, extra)
    return vim.tbl_extend("force", {
        ok = false,
        reason = reason,
        provider = "tinymist",
        method = METHOD,
        command = command_object and command_object.command or nil,
        message = message,
    }, extra or {})
end

local function execute_with_exec_cmd(client, command_object, bufnr, opts)
    if type(client.exec_cmd) ~= "function" then
        return nil
    end

    local context = {
        bufnr = bufnr,
        client_id = client.id,
        method = opts.source_method or METHOD,
    }
    local ok, err = pcall(client.exec_cmd, client, command_object, context)
    if not ok then
        log.add("warn", "Tinymist exec_cmd failed", {
            client = client.name,
            command = command_object.command,
            error = err,
        })
        return failure("exec_cmd_failed", tostring(err), command_object, {
            client = client.name,
            error = err,
        })
    end

    return success_result(client, command_object, nil, {
        executed = true,
        transport = "exec_cmd",
    })
end

local function execute_with_request(client, command_object, params, bufnr, opts)
    if
        type(client.request) ~= "function"
        or not clients.supports_method(client, METHOD, bufnr)
    then
        return nil
    end

    local callback = opts.callback
    if type(callback) == "function" then
        return request_async.request(
            bufnr,
            METHOD,
            function()
                return params
            end,
            vim.tbl_extend("force", opts, {
                client = client,
                guard_cursor = false,
            }),
            callback,
            function(result, request_client)
                return success_result(request_client, command_object, result, {
                    executed = true,
                    transport = "workspace_request",
                })
            end
        )
    end

    local request_start = lsp_request.start(client, METHOD, params, nil, bufnr)
    if not request_start.ok and request_start.called == false then
        return failure(
            "request_failed",
            request_start.message,
            command_object,
            {
                client = client.name,
                error = request_start.error,
            }
        )
    end
    if not request_start.ok then
        return failure(
            "request_failed",
            "Tinymist executeCommand request failed",
            command_object,
            { client = client.name }
        )
    end

    return success_result(client, command_object, nil, {
        pending = true,
        request_id = request_start.request_id,
        transport = "workspace_request",
    })
end

--- Execute a Tinymist command through the attached Neovim LSP client.
---@param command string|table Command name or LSP Command object.
---@param arguments? table Command arguments; overrides `command.arguments`.
---@param opts? table Execution options with `bufnr`, `client`, `callback`, and `source_method`.
---@return table result Execution result, pending request, or failure payload.
function M.execute_command(command, arguments, opts)
    opts = opts or {}
    local bufnr = clients.normalize_bufnr(opts.bufnr)
    local command_object, params, err =
        normalize_command(command, arguments, opts)
    if not command_object then
        return immediate(
            opts.callback,
            failure(err, "Invalid Tinymist command")
        )
    end

    local command_clients_list, selected = command_clients(bufnr, opts)
    local saw_client = false
    local exec_cmd_failure = nil
    for _, client in ipairs(command_clients_list) do
        saw_client = true

        local exec_result =
            execute_with_exec_cmd(client, command_object, bufnr, opts)
        if exec_result and exec_result.ok then
            return immediate(opts.callback, exec_result)
        elseif exec_result then
            exec_cmd_failure = exec_result
        end

        local request_result =
            execute_with_request(client, command_object, params, bufnr, opts)
        if request_result then
            return request_result
        end
    end

    local result = saw_client
            and (exec_cmd_failure or failure(
                "unsupported",
                "Tinymist executeCommand is unavailable",
                command_object
            ))
        or failure(
            selected and selected.reason or "no_client",
            selected and selected.message
                or "Tinymist Neovim LSP client is not attached",
            command_object,
            selected
        )
    return immediate(opts.callback, result)
end

return M
