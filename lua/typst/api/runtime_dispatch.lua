local context = require("typst.api.context")
local results = require("typst.api.runtime_results")

local M = {}

local custom_handlers = {}

local call_styles = {}

local unpack = table.unpack or unpack

local function pack_returns(...)
    return {
        n = select("#", ...),
        ...,
    }
end

call_styles.project_opts_callback_notify = function(
    method,
    resolved,
    callback,
    env
)
    return method(resolved.project, resolved.opts, callback, env.notify)
end

call_styles.project_callback_notify = function(method, resolved, callback, env)
    return method(resolved.project, callback, env.notify)
end

call_styles.opts_callback_notify = function(method, resolved, callback, env)
    return method(resolved.opts, callback, env.notify)
end

call_styles.project_opts_notify = function(method, resolved, _callback, env)
    return method(resolved.project, resolved.opts, env.notify)
end

call_styles.project_opts = function(method, resolved)
    return method(resolved.project, resolved.opts)
end

call_styles.project_only = function(method, resolved)
    return method(resolved.project)
end

call_styles.opts = function(method, resolved)
    return method(resolved.opts)
end

custom_handlers["project.operations"] = function(_endpoint, resolved)
    local snapshot =
        require("typst.project.services").snapshot(resolved.project)
    return snapshot and snapshot.operations or nil
end

local function ensure_namespace(api, name)
    api[name] = api[name] or {}
    return api[name]
end

local function prepared_opts(endpoint, opts, env)
    if type(opts) ~= "table" then
        opts = opts == nil and {} or { bufnr = opts }
    end
    if endpoint.args and endpoint.args.normalize_bufnr then
        local normalize = env.normalize_bufnr
        if type(normalize) == "function" then
            return vim.tbl_extend("force", opts, {
                bufnr = normalize(opts.bufnr),
            })
        end
    end
    return opts
end

local function load_method(endpoint, env)
    local handler = endpoint.handler or {}
    if handler.custom then
        local custom = custom_handlers[handler.custom]
        if type(custom) ~= "function" then
            return nil, results.handler_missing(endpoint)
        end
        return custom
    end

    local module = require(handler.module)
    if handler.factory then
        module = module[handler.factory]({
            notify = env and env.notify or nil,
        })
    end

    local method = module[handler.method]
    if type(method) ~= "function" then
        return nil, results.handler_missing(endpoint)
    end
    return method
end

function M.call_handler(endpoint, resolved, callback, env)
    local result_policy = endpoint.result or {}
    local handler = endpoint.handler or {}

    local function invoke()
        local method, load_err = load_method(endpoint, env)
        if not method then
            return load_err
        end
        if handler.custom then
            return method(endpoint, resolved, callback, env)
        end

        local call = call_styles[handler.call]
        if not call then
            return results.invalid_handler_call(endpoint)
        end
        return call(method, resolved, callback, env)
    end

    if result_policy.protect_handler == false then
        return invoke()
    end

    local returned = pack_returns(xpcall(invoke, debug.traceback))
    if returned[1] then
        return unpack(returned, 2, returned.n)
    end
    return results.route_handler_exception(
        endpoint,
        returned[2],
        callback,
        env.notify
    )
end

function M.wrap(endpoint, env)
    env = env or {}
    return function(opts, callback)
        opts = prepared_opts(endpoint, opts, env)
        local resolved = context.resolve_endpoint(endpoint, opts, env.notify)
        if not resolved.ok then
            return results.route_resolution_error(
                endpoint,
                resolved.error,
                callback,
                env.notify,
                opts
            )
        end
        return M.call_handler(endpoint, resolved, callback, env)
    end
end

function M.install(api, endpoints, env)
    for _, endpoint in ipairs(endpoints or {}) do
        local namespace = ensure_namespace(api, endpoint.namespace)
        namespace[endpoint.name] = M.wrap(endpoint, env)
    end
end

return M
