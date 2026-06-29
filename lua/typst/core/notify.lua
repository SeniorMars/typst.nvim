local M = {}

--- Send a typst.nvim notification through the default Neovim UI.
---@param message string Message to show.
---@param level? integer `vim.log.levels` severity; defaults to INFO.
function M.default(message, level)
    vim.notify(message, level or vim.log.levels.INFO, { title = "typst.nvim" })
end

--- Notify through an injected sink, falling back to Neovim's notification UI.
---@param notify? fun(message:string, level?:integer) Optional caller-provided sink.
---@param message string Message to show.
---@param level? integer `vim.log.levels` severity; defaults to INFO.
function M.user(notify, message, level)
    if notify then
        notify(message, level)
        return
    end
    M.default(message, level)
end

--- Notify for a conventional `{ ok, message }` result table.
---@param result table Result with optional `ok` and `message` fields.
---@param policy? {notify?:fun(message:string,level?:integer),success?:string,failure?:string,success_level?:integer,failure_level?:integer,notify_false?:boolean}
---@return boolean notified True when a notification was emitted.
function M.result(result, policy)
    policy = policy or {}
    if policy.notify_false or type(result) ~= "table" then
        return false
    end

    local ok = result.ok ~= false
    local message = result.message or (ok and policy.success or policy.failure)
    if not message or message == "" then
        return false
    end

    M.user(
        policy.notify,
        message,
        ok and (policy.success_level or vim.log.levels.INFO)
            or (policy.failure_level or vim.log.levels.WARN)
    )
    return true
end

return M
