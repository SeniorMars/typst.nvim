local log = require("typst.core.log")
local core_result = require("typst.core.result")

local M = {}

local function protected_stop_callback(callback, payload)
    local ok, err = pcall(callback, payload)
    if not ok then
        log.add("warn", "watcher stop callback failed", {
            error = err,
        })
    end
end

local function stop_payload(defaults, result)
    local payload = vim.tbl_extend(
        "force",
        defaults or {},
        type(result) == "table" and result or {}
    )
    if payload.stopped == nil then
        payload.stopped = payload.ok ~= false
            and payload.pending ~= true
            and payload.orphaned ~= true
            and payload.retained ~= true
            and payload.orphan_retained ~= true
            and not core_result.is_unconfirmed_stop(payload)
    end
    return payload
end

function M.payload(watcher, result)
    return stop_payload({
        deps_path = watcher and watcher.deps_path or nil,
        stale = false,
        watch = true,
    }, result)
end

local function operation_stop_callback(operation_handle)
    if operation_handle and type(operation_handle.on_settle) == "function" then
        return "on_settle"
    end
    if operation_handle and type(operation_handle.on_result) == "function" then
        return "on_result"
    end
end

--- Add a callback to an in-flight watch stop transition.
---@param watcher TypstCompilerWatcher Watcher state stored in project compiler state.
---@param callback? fun(result:TypstCompilerResult) Callback invoked when the stop settles.
function M.add_callback(watcher, callback)
    if type(callback) ~= "function" then
        return
    end

    local callback_method = watcher
            and operation_stop_callback(watcher.operation)
        or nil
    if callback_method then
        watcher.operation[callback_method](watcher.operation, function(result)
            protected_stop_callback(callback, M.payload(watcher, result))
        end)
        return
    end

    watcher.stop_callbacks = watcher.stop_callbacks or {}
    watcher.stop_callbacks[#watcher.stop_callbacks + 1] = callback
end

--- Drain callbacks for a completed watcher stop exactly once.
---@param watcher TypstCompilerWatcher? Watcher state stored in project compiler state.
---@param payload TypstCompilerResult Stop result passed to each callback.
function M.drain_callbacks(watcher, payload)
    local callbacks = watcher and watcher.stop_callbacks or {}
    if watcher then
        watcher.stop_callbacks = nil
    end

    for _, stop_callback in ipairs(callbacks) do
        protected_stop_callback(stop_callback, payload)
    end
end

return M
