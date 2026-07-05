local clients = require("typst.integrations.tinymist.clients")
local commands = require("typst.integrations.tinymist.commands")
local log = require("typst.core.log")
local request_async = require("typst.integrations.tinymist.async")
local position = require("typst.integrations.tinymist.position")

local M = {}

local function async_required(method)
    return {
        ok = false,
        reason = "async_required",
        provider = "tinymist",
        method = method,
        message = "Tinymist code actions require a callback",
    }
end

local function config()
    local ok, typst_config = pcall(require, "typst.config")
    if not ok then
        return {
            timeout_ms = 1000,
            patterns = {},
        }
    end

    return typst_config.unsafe_get().structural_actions
end

local function params(bufnr, client, opts)
    opts = opts or {}
    local text_document = vim.lsp.util.make_text_document_params(bufnr)
    local range = opts.range or position.current_range(bufnr, client)
    if not range then
        return nil
    end
    local context = vim.tbl_deep_extend("force", {
        diagnostics = {},
        triggerKind = vim.lsp.protocol.CodeActionTriggerKind.Invoked,
    }, opts.context or {})
    return {
        textDocument = text_document,
        range = range,
        context = context,
    }
end

local function action_lines(action)
    local lines = {}
    if type(action.title) == "string" then
        lines[#lines + 1] = action.title
    end
    if type(action.kind) == "string" then
        lines[#lines + 1] = action.kind
    end
    if type(action.command) == "string" then
        lines[#lines + 1] = action.command
    elseif
        type(action.command) == "table"
        and type(action.command.command) == "string"
    then
        lines[#lines + 1] = action.command.command
        if type(action.command.title) == "string" then
            lines[#lines + 1] = action.command.title
        end
    end
    return table.concat(lines, "\n"):lower()
end

local function matches_patterns(action, patterns)
    if action.disabled then
        return false
    end

    local haystack = action_lines(action)
    for _, pattern in ipairs(patterns or {}) do
        if haystack:match(pattern:lower()) then
            return true
        end
    end

    return false
end

local function has_async_code_action_client(bufnr)
    for _, client in ipairs(clients.clients(bufnr)) do
        if
            type(client.request) == "function"
            and clients.supports_method(
                client,
                "textDocument/codeAction",
                bufnr
            )
        then
            return true
        end
    end
    return false
end

local function action_command(action)
    if type(action.command) == "table" then
        return action.command
    end

    if type(action.command) == "string" and not action.edit then
        return action
    end
end

--- Request Tinymist code actions for a buffer range.
---@param bufnr? integer Buffer to query.
---@param opts? table Code-action options; `callback` enables async results.
---@return table? result Pending request handle, immediate action list, or nil when unsupported.
function M.code_actions(bufnr, opts)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    opts = opts or {}
    local actions = {}

    if type(opts.callback) == "function" then
        if not has_async_code_action_client(bufnr) then
            opts.callback({
                ok = false,
                provider = "tinymist",
                reason = "unsupported",
                actions = {},
                message = "Tinymist code actions require an asynchronous client",
            })
            return nil
        end

        return request_async.request(
            bufnr,
            "textDocument/codeAction",
            function(client)
                return params(bufnr, client, opts)
            end,
            opts,
            opts.callback,
            function(result, client)
                local normalized = {}
                for _, action in ipairs(result or {}) do
                    normalized[#normalized + 1] = {
                        action = action,
                        client = client,
                    }
                end
                return {
                    ok = true,
                    provider = "tinymist",
                    client = client.name,
                    actions = normalized,
                }
            end
        )
    end

    return actions
end

--- Find the first Tinymist code action matching a configured action name.
---@param bufnr integer Buffer to query.
---@param action_name string Configured structural-action name.
---@param opts? table Code-action options; `callback` enables async lookup.
---@return table? candidate Matching candidate for synchronous callers.
function M.find_code_action(bufnr, action_name, opts)
    opts = opts or {}
    local patterns = opts.patterns
        or (config().patterns and config().patterns[action_name])
        or {}

    if type(opts.callback) == "function" then
        local callback = opts.callback
        local request_opts = vim.tbl_extend("force", opts, {
            callback = function(result)
                if not result.ok then
                    callback(result)
                    return
                end
                for _, candidate in ipairs(result.actions or {}) do
                    if matches_patterns(candidate.action, patterns) then
                        callback({
                            ok = true,
                            provider = "tinymist",
                            candidate = candidate,
                        })
                        return
                    end
                end
                callback({
                    ok = false,
                    reason = "no_action",
                    provider = "tinymist",
                    message = ("No matching Tinymist code action for %s"):format(
                        action_name
                    ),
                })
            end,
        })
        return M.code_actions(bufnr, request_opts)
    end

    for _, candidate in ipairs(M.code_actions(bufnr, opts) or {}) do
        if matches_patterns(candidate.action, patterns) then
            return candidate
        end
    end
end

--- Apply a resolved Tinymist code-action candidate.
---@param candidate table Candidate containing the LSP action and client.
---@param opts? table Apply options; `bufnr` is used for command execution.
---@return table action Applied LSP code action.
function M.apply_code_action(candidate, opts)
    opts = opts or {}
    local action = candidate.action
    local client = candidate.client
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if action.disabled then
        return {
            ok = false,
            reason = "disabled",
            provider = "tinymist",
            action = action,
            client = client,
            message = action.disabled.reason
                or "Tinymist code action is disabled",
        }
    end
    if action.edit then
        vim.lsp.util.apply_workspace_edit(
            action.edit,
            client.offset_encoding or "utf-16"
        )
    end

    local command = action_command(action)
    if command then
        commands.execute_command(command, nil, {
            bufnr = bufnr,
            client = client,
            source_method = "textDocument/codeAction",
        })
    end

    log.add("info", "tinymist code action applied", {
        title = action.title,
        command = command and command.command or nil,
    })
    return action
end

local function apply_code_action_async(candidate, opts, callback)
    opts = opts or {}
    local action = candidate.action
    local client = candidate.client
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local timeout_ms = opts.timeout_ms or config().timeout_ms

    if action.disabled then
        local result = {
            ok = false,
            reason = "disabled",
            provider = "tinymist",
            action = action,
            client = client,
            message = action.disabled.reason
                or "Tinymist code action is disabled",
        }
        callback(result)
        return result
    end

    local function apply(action_result)
        if action_result.disabled then
            callback({
                ok = false,
                reason = "disabled",
                provider = "tinymist",
                action = action_result,
                client = client,
                message = action_result.disabled.reason
                    or "Tinymist code action is disabled",
            })
            return
        end

        if action_result.edit then
            vim.lsp.util.apply_workspace_edit(
                action_result.edit,
                client.offset_encoding or "utf-16"
            )
        end

        local command = action_command(action_result)
        if command then
            commands.execute_command(command, nil, {
                bufnr = bufnr,
                client = client,
                source_method = "textDocument/codeAction",
            })
        end

        log.add("info", "tinymist code action applied", {
            title = action_result.title,
            command = command and command.command or nil,
        })
        callback({
            ok = true,
            provider = "tinymist",
            action = action_result,
            client = client,
        })
    end

    if action.edit or action.command or not action.data then
        apply(action)
        return {
            ok = true,
            provider = "tinymist",
            action = action,
            client = client,
        }
    end

    if
        type(client.request) ~= "function"
        or (
            type(client.supports_method) == "function"
            and not client:supports_method("codeAction/resolve", bufnr)
        )
    then
        apply(action)
        return {
            ok = true,
            provider = "tinymist",
            action = action,
            client = client,
        }
    end

    return request_async.request(
        bufnr,
        "codeAction/resolve",
        function()
            return action
        end,
        vim.tbl_extend("force", opts, {
            client = client,
            timeout_ms = timeout_ms,
        }),
        function(result)
            if not result.ok then
                callback(result)
                return
            end
            apply(result.action or action)
        end,
        function(result)
            return {
                ok = true,
                provider = "tinymist",
                client = client.name,
                action = result or action,
            }
        end
    )
end

--- Apply a resolved or resolvable Tinymist code action asynchronously.
---@param candidate table Candidate containing the LSP action and client.
---@param opts? table Apply options; `bufnr` and timeout controls are forwarded.
---@param callback fun(result:table) Callback invoked after apply/resolve finishes.
---@return table? result Immediate result or pending resolve request.
function M.apply_code_action_async(candidate, opts, callback)
    return apply_code_action_async(candidate, opts, callback)
end

--- Run a configured Tinymist structural code action.
---@param action_name string Configured action name to match.
---@param opts? table Structural-action options; `callback` is required for LSP execution.
---@return table? result Pending request handle or immediate failure payload.
function M.structural_action(action_name, opts)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()

    if type(opts.callback) == "function" then
        local callback = opts.callback
        if not has_async_code_action_client(bufnr) then
            local result = {
                ok = false,
                reason = "unsupported",
                provider = "tinymist",
                message = "Tinymist structural actions require an asynchronous client",
            }
            callback(result)
            return result
        end

        return M.find_code_action(
            bufnr,
            action_name,
            vim.tbl_extend("force", opts, {
                callback = function(result)
                    if not result.ok then
                        callback(result)
                        return
                    end
                    apply_code_action_async(
                        result.candidate,
                        vim.tbl_extend("force", opts, { bufnr = bufnr }),
                        callback
                    )
                end,
            })
        )
    end

    if not clients.available(bufnr) then
        return {
            ok = false,
            reason = "no_client",
            message = "Tinymist Neovim LSP client is not attached",
        }
    end

    return async_required("textDocument/codeAction")
end

return M
