local config = require("typst.config")
local async = require("typst.core.async")
local buffer = require("typst.core.buffer")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local reports = require("typst.ui.reports")
local util = require("typst.core.util")

local M = {}

local notify_user = require("typst.core.notify").user

local function provider_eval(project, opts, callback)
    local provider = providers.resolve("eval", opts.provider)
    if provider == nil or provider == "typst" then
        return nil
    end
    local provider_project = providers.project_context(project)
    local provider_callback = callback
        and function(result)
            callback(result, provider_project)
        end
    return provider_adapter.invoke(
        provider,
        { "eval", "run" },
        provider_project,
        opts,
        {
            kind = "eval",
            provider_name = type(provider) == "table" and provider.name
                or "callback",
            args = { provider_project, opts },
            callback_position = 3,
            timeout_ms = opts.timeout_ms or 10000,
            on_result = provider_callback,
            result_fields = {
                output = true,
                stdout = true,
                stderr = true,
                text = true,
                value = true,
                values = true,
            },
            invalid_result_message = "Eval provider returned no result",
        }
    )
end

local function command_for(project, expression, opts)
    local cfg = config.unsafe_get()
    local command = vim.list_extend(util.command_prefix(cfg.executable), {
        "eval",
        "--root",
        project.root,
        "--in",
        opts.context or project.main,
    })

    if opts.target then
        command[#command + 1] = "--target"
        command[#command + 1] = opts.target
    end

    if opts.format then
        command[#command + 1] = "--format"
        command[#command + 1] = opts.format
    end

    if opts.pretty ~= false then
        command[#command + 1] = "--pretty"
    end

    for _, arg in ipairs(opts.extra_args or {}) do
        command[#command + 1] = arg
    end

    command[#command + 1] = expression
    return command
end

local function open_result(result)
    local lines = {
        "typst.nvim eval",
        ("  expression: %s"):format(result.expression or ""),
        ("  exit: %s"):format(vim.inspect(result.code)),
        "",
    }

    for _, line in ipairs(util.split_lines(result.stdout or "")) do
        lines[#lines + 1] = line
    end
    if result.stderr and result.stderr ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "stderr:"
        for _, line in ipairs(util.split_lines(result.stderr)) do
            lines[#lines + 1] = line
        end
    end

    return reports.open_scratch_buffer("typst.nvim eval", "typsteval", lines)
end

--- Evaluate a Typst expression in the context of a project.
---@param project table Project state that supplies root and main-file context.
---@param opts? table Eval options; `expression`/`args` provides source to evaluate.
---@param callback? fun(result:table, context?:table) Terminal eval result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Pending operation handle or immediate failure/provider result.
function M.eval(project, opts, callback, notify)
    opts = opts or {}
    local expression = vim.trim(opts.expression or opts.args or "")
    if expression == "" then
        return {
            ok = false,
            reason = "empty_expression",
            message = "No Typst expression was provided",
        }
    end

    local provider_result = provider_eval(project, opts, callback)
    if provider_result ~= nil then
        return provider_result
    end

    local command = command_for(project, expression, opts)
    local result = {
        ok = true,
        pending = true,
        expression = expression,
        command = command,
    }

    notify_user(notify, "Evaluating Typst expression")
    operation.attach(result, "eval", command, {
        cwd = project.root,
        text = true,
        detach = false,
    }, {
        on_finish = function(exit)
            if async.cancelled(result) then
                return
            end
            result.pending = false
            result.code = exit.code
            result.stdout = exit.stdout
            result.stderr = exit.stderr
            result.ok = exit.code == 0
            if opts.open ~= false then
                result.buffer = open_result(result)
            end
            log.add(result.ok and "info" or "error", "typst eval finished", {
                code = result.code,
                expression = expression,
            })
            notify_user(
                notify,
                result.ok and "Typst eval finished" or "Typst eval failed",
                result.ok and vim.log.levels.INFO or vim.log.levels.ERROR
            )
            if callback then
                callback(result, providers.project_context(project))
            end
        end,
    })

    return result
end

local function valid_window_for_buffer(winid, bufnr)
    return winid
        and vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == bufnr
end

local function explicit_range(opts)
    local line1 = tonumber(opts.line1)
    local line2 = tonumber(opts.line2)
    if line1 and line2 then
        return line1, line2
    end
end

local function current_visual_range(bufnr)
    if bufnr ~= vim.api.nvim_get_current_buf() then
        return nil, nil
    end

    local mode = vim.fn.mode(1)
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        return nil, nil
    end

    local start_mark = vim.api.nvim_buf_get_mark(bufnr, "<")
    local end_mark = vim.api.nvim_buf_get_mark(bufnr, ">")
    if start_mark[1] <= 0 or end_mark[1] <= 0 then
        return nil, nil
    end
    return start_mark[1], end_mark[1]
end

local function selection_lines(opts)
    local bufnr = buffer.normalize_bufnr(opts.bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, "invalid_buffer"
    end

    local line1, line2 = explicit_range(opts)
    if not line1 then
        line1, line2 = current_visual_range(bufnr)
    end

    if not line1 then
        local winid = opts.winid
        if winid == nil and bufnr == vim.api.nvim_get_current_buf() then
            winid = vim.api.nvim_get_current_win()
        end
        if not valid_window_for_buffer(winid, bufnr) then
            return nil, "position_required"
        end
        line1 = vim.api.nvim_win_get_cursor(winid)[1]
        line2 = line1
    end

    if line2 < line1 then
        line1, line2 = line2, line1
    end
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    line1 = math.max(1, math.min(line_count, line1))
    line2 = math.max(1, math.min(line_count, line2))
    return table.concat(
        vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false),
        "\n"
    )
end

--- Evaluate the selected Typst source in the context of a project.
---@param project table Project state that supplies root and main-file context.
---@param opts? table Selection eval options; buffer/range fields select the source.
---@param callback? fun(result:table, context?:table) Terminal eval result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Pending operation handle or immediate failure/provider result.
function M.eval_selection(project, opts, callback, notify)
    opts = opts or {}
    if not opts.expression or opts.expression == "" then
        local expression, reason = selection_lines(opts)
        if not expression then
            return {
                ok = false,
                reason = reason,
                message = "No valid Typst selection range was found",
            }
        end
        opts.expression = expression
    end
    return M.eval(project, opts, callback, notify)
end

--- Evaluate and open an inspection report for a Typst expression.
---@param project table Project state that supplies root and main-file context.
---@param opts? table Inspect options; defaults to the word under cursor.
---@param callback? fun(result:table, context?:table) Terminal inspect result callback.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Pending operation handle or immediate failure/provider result.
function M.inspect(project, opts, callback, notify)
    opts = opts or {}
    if not opts.expression or opts.expression == "" then
        opts.expression = vim.fn.expand("<cword>")
    end
    opts.pretty = opts.pretty ~= false
    opts.open = opts.open ~= false
    return M.eval(project, opts, callback, notify)
end

return M
