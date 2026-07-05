local log = require("typst.core.log")
local notify = require("typst.core.notify")

local M = {}

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

local function command_callback(name, callback)
    return function(args)
        local ok, result = xpcall(function()
            return callback(args)
        end, debug.traceback)
        if ok then
            return result
        end

        log.add("error", "command failed", {
            command = name,
            error = result,
        })
        notify.default(
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
