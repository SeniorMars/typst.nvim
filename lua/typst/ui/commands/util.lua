local log = require("typst.core.log")
local notify = require("typst.core.notify")
local pending = require("typst.core.pending")
local unpack = require("typst.core.tables").unpack

local M = {}

local active_command = nil
local result_notify = notify.default

---@class TypstCommandOptions
---@field desc string
---@field nargs any
---@field complete? string|fun(argLead:string, cmdline:string, cursorPos:integer):string[]|nil
---@field bang boolean|nil
---@field range boolean|nil
---@field force boolean|nil

--- Build common options for a user command.
---@param desc string Command description.
---@param nargs? string|integer Argument count accepted by `nvim_create_user_command`.
---@param complete? string|fun(argLead:string, cmdline:string, cursorPos:integer):string[]|nil Completion callback or Neovim completion mode.
---@return TypstCommandOptions opts Command option table.
function M.opts(desc, nargs, complete)
    return {
        desc = desc,
        nargs = nargs or 0,
        complete = complete,
    }
end

local function command_exists(name)
    return vim.fn.exists(":" .. name) == 2
end

local function short_error(err)
    local message = tostring(err or "unknown error")
    local typst_message = message:match("(typst%.nvim:[^\n]*)")
    if typst_message then
        return typst_message
    end
    return (message:match("([^\n]+)") or message):gsub("^%s+", "")
end

local function pack_returns(...)
    return { n = select("#", ...), ... }
end

local function unpack_returns(values)
    return unpack(values, 1, values.n or #values)
end

local function failure_message(failure, name)
    if type(failure) == "table" then
        return failure.message
            or failure.reason
            or ("Typst command failed: " .. name)
    end
    return tostring(failure or ("Typst command failed: " .. name))
end

local function failure_level(failure)
    if type(failure) ~= "table" then
        return vim.log.levels.WARN
    end
    if type(failure.notify_level) == "number" then
        return failure.notify_level
    end
    if failure.level == "error" or failure.severity == "error" then
        return vim.log.levels.ERROR
    end
    if
        failure.reason == "unknown_project_key"
        or failure.reason == "ambiguous_project_key"
        or failure.reason == "exception"
    then
        return vim.log.levels.ERROR
    end
    return vim.log.levels.WARN
end

local function is_failure_notification(level)
    return type(level) == "number" and level >= vim.log.levels.WARN
end

local function is_pending_result(value)
    return type(value) == "table" and value.pending == true
end

--- Report structured command callback failures.
---
--- Public APIs should return normal structured failures for expected user
--- errors. Commands still need one boundary that turns those payloads into
--- visible UI feedback, just as thrown errors already do.
---@param name string Command name.
---@param values table Packed callback returns.
---@return any ...
function M.report_result(name, values, context)
    local result = values and values[1] or nil
    local err = values and values[2] or nil
    local failure = nil

    if
        err ~= nil
        and (result == nil or result == false)
        and not is_pending_result(err)
    then
        failure = err
    elseif
        type(result) == "table"
        and result.ok == false
        and not is_pending_result(result)
    then
        failure = result
    elseif result == false and err ~= nil and not is_pending_result(err) then
        failure = err
    end

    if not failure then
        return unpack_returns(values or { n = 0 })
    end

    log.add("warn", "command returned failure", {
        command = name,
        error = failure,
    })
    if not (context and context.failure_notified == true) then
        local notify_fn = context and context.notify or result_notify
        notify_fn(failure_message(failure, name), failure_level(failure))
    end
    return nil
end

--- Report the eventual result of a command-created pending handle.
---
--- Async command operations finish after the command callback's duplicate
--- suppression context is gone, but they should still use the same failure
--- formatting and notification sink as synchronous command returns.
---@param name string Command name.
---@param result any Result delivered by a pending handle.
---@param context? table Command result context.
---@return any result Original result for callback chaining.
function M.report_async_result(name, result, context)
    if is_pending_result(result) then
        return result
    end
    M.report_result(name, { n = 1, result }, context)
    return result
end

local function attach_async_reporter(name, values, context)
    local result = values and values[1] or nil
    local err = values and values[2] or nil
    local pending_result = is_pending_result(result) and result
        or is_pending_result(err) and err
        or nil
    if not pending_result then
        return
    end
    if pending_result._typst_command_async_reporter == name then
        return
    end
    pending_result._typst_command_async_reporter = name
    local notify_fn = context and context.notify or result_notify
    pending.subscribe_compatible(pending_result, function(done)
        M.report_async_result(name, done, {
            notify = notify_fn,
        })
    end)
end

--- Set the notification sink used for returned structured command failures.
---@param notify_fn? fun(message:string, level?:integer)
---@return fun(message:string, level?:integer) previous Previously configured sink.
function M.set_result_notify(notify_fn)
    local previous = result_notify
    result_notify = type(notify_fn) == "function" and notify_fn
        or notify.default
    return previous
end

--- Wrap a command notification sink so command result reporting can avoid
--- emitting the same structured failure twice.
---
--- Duplicate suppression only applies to notifications emitted through this
--- command-scoped wrapper during the synchronous command callback.
--- Command-facing code should use ctx.notify for expected failures.
---@param notify_fn fun(message:string, level?:integer)
---@return fun(message:string, level?:integer)
function M.command_notify(notify_fn)
    return function(message, level)
        if active_command and is_failure_notification(level) then
            active_command.failure_notified = true
        end
        return notify_fn(message, level)
    end
end

local function command_callback(name, callback)
    return function(args)
        local context = {
            failure_notified = false,
            notify = result_notify,
        }
        local previous_context = active_command
        active_command = context
        local ok, result = xpcall(function()
            return pack_returns(callback(args))
        end, debug.traceback)
        active_command = previous_context
        if ok then
            attach_async_reporter(name, result, context)
            return M.report_result(name, result, context)
        end

        log.add("error", "command failed", {
            command = name,
            error = result,
        })
        context.notify(
            ("Typst command failed: %s"):format(short_error(result)),
            vim.log.levels.ERROR
        )
        return nil
    end
end

--- Create a typst.nvim user command unless delegation is requested.
---@param name string User command name.
---@param callback function Command callback.
---@param opts? TypstCommandOptions Command options.
function M.create(name, callback, opts)
    opts = opts or {}
    -- Some command names, especially TypstPreview*, may already belong to
    -- companion plugins. force=false means typst.nvim delegates instead of
    -- shadowing the user's existing integration.
    if opts.force == false and command_exists(name) then
        log.add("info", "kept existing command", { command = name })
        return
    end

    local command_opts = vim.deepcopy(opts)
    command_opts.force = nil
    ---@cast command_opts vim.api.keyset.user_command
    vim.api.nvim_create_user_command(
        name,
        command_callback(name, callback),
        command_opts
    )
end

--- Extract range/count fields from Neovim command callback args.
---@param args? table User command callback arguments.
---@return table opts Range option table for workflow/edit APIs.
function M.range_opts(args)
    args = args or {}
    local opts = {
        line1 = args.line1,
        line2 = args.line2,
        range = args.range,
    }
    if type(args.count) == "number" and args.count > 0 then
        opts.count = args.count
    end
    return opts
end

return M
