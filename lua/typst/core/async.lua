local process = require("typst.core.process")

local M = {}

local function list_from(value)
    if type(value) ~= "table" then
        return {}
    end
    if value[1] ~= nil then
        return value
    end
    return { value }
end

--- Stop and close a libuv timer if it is still open.
---@param timer? userdata Timer handle.
function M.close_timer(timer)
    if not timer then
        return
    end

    pcall(function()
        if not timer:is_closing() then
            timer:stop()
            timer:close()
        end
    end)
end

--- Run immediately outside fast events, or schedule onto the main loop inside one.
---@param fn fun() Callback to run.
function M.schedule(fn)
    if vim.in_fast_event and vim.in_fast_event() then
        vim.schedule(fn)
    else
        fn()
    end
end

--- Cancel an in-flight Neovim LSP request when the client supports it.
---@param client? table LSP client object.
---@param request_id any Request id returned by `client.request`.
---@return boolean cancelled True when the request was accepted for cancellation.
function M.cancel_lsp_request(client, request_id)
    if not client or request_id == nil or request_id == false then
        return false
    end
    if type(client.cancel_request) ~= "function" then
        return false
    end

    local ok, cancelled = pcall(client.cancel_request, client, request_id)
    return ok and cancelled ~= false
end

--- Shut down one system process handle.
---@param handle? userdata Process handle to stop.
---@param opts? table Shutdown options forwarded to process helpers.
---@return boolean ok True when the handle stopped or was already idle.
---@return table result Shutdown result payload.
function M.cancel_system(handle, opts)
    if not handle then
        return true,
            {
                stopped = true,
                idle = true,
            }
    end

    return process.shutdown(handle, opts)
end

--- Shut down one or more system process handles.
---@param handles userdata|userdata[]|table|nil Process handle or list-like handle table.
---@param opts? table Shutdown options forwarded to process helpers.
---@return boolean stopped True when all handles stopped.
---@return table result Aggregate shutdown result.
function M.cancel_handles(handles, opts)
    handles = list_from(handles)
    local stopped = true
    local results = {}

    for _, handle in ipairs(handles) do
        local ok, result = M.cancel_system(handle, opts)
        results[#results + 1] = result
        if not ok then
            stopped = false
        end
    end

    return stopped,
        {
            stopped = stopped,
            results = results,
        }
end

--- Attach a standard cancel method to a pending result table.
---@param result table Mutable pending result table.
---@param opts? table Cancel options, including handles or `on_cancel`.
---@return table result The same result table with `cancel` attached.
function M.attach_result(result, opts)
    opts = opts or {}
    result.cancel = function(cancel_opts)
        if result.pending == false then
            return true,
                {
                    stopped = true,
                    idle = true,
                }
        end

        result.cancelled = true
        result.pending = false
        result.ok = false
        result.reason = "cancelled"

        if type(opts.on_cancel) == "function" then
            pcall(opts.on_cancel, result, cancel_opts or {})
        end

        local handles
        if type(opts.handles) == "function" then
            handles = opts.handles(result)
        elseif opts.handles ~= nil then
            handles = opts.handles
        elseif result.handles ~= nil then
            handles = result.handles
        else
            handles = result.handle
        end

        local stopped, cancel_result = M.cancel_handles(handles, cancel_opts)
        result.cancel_result = cancel_result
        return stopped, cancel_result
    end
    return result
end

--- Check whether a pending result has been cancelled.
---@param result any Result object to inspect.
---@return boolean cancelled True when the result table is marked cancelled.
function M.cancelled(result)
    return type(result) == "table" and result.cancelled == true
end

return M
