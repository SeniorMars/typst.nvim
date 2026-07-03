local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr
local path_util = require("typst.core.path")

local function typst_buffer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if vim.bo[bufnr].filetype == "typst" then
        return true
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    return type(name) == "string" and name:match("%.typ$") ~= nil
end

local function no_project(operation, bufnr)
    return {
        ok = false,
        reason = "no_project",
        operation = operation,
        bufnr = bufnr,
        message = ("No Typst project is attached for buffer %s; run from a Typst buffer or pass { bufnr = ..., project = ..., key = ... }"):format(
            tostring(bufnr)
        ),
    }
end

local function should_notify(opts, policy)
    if opts.notify ~= nil then
        return opts.notify == true
    end
    if policy.notify ~= nil then
        return policy.notify == true
    end
    return policy.passive ~= true
end

local function maybe_notify(opts, policy, notify, err, level)
    if should_notify(opts, policy) and type(notify) == "function" then
        notify(err.message, level or vim.log.levels.WARN)
    end
end

local function project_from_key(opts, policy)
    local key = opts.key
        or opts.project_key
        or (type(opts.project) == "string" and opts.project or nil)
    if type(key) ~= "string" or key == "" then
        return nil
    end

    local store = require("typst.project.store")
    local state, key_error, decoded
    if opts.key_encoded == true then
        state = store.get_encoded(key)
        decoded = store.decode_key(key)
    else
        state, key_error, decoded = store.resolve_key(key)
    end
    if state then
        return {
            ok = true,
            project = state,
            key = key,
            decoded_key = decoded,
        }
    end

    local reason = key_error or "unknown_project_key"
    return {
        ok = false,
        error = {
            ok = false,
            reason = reason,
            operation = policy.operation,
            key = key,
            decoded_key = decoded,
            message = reason == "ambiguous_project_key"
                    and ("Ambiguous Typst project key: " .. key)
                or ("Unknown Typst project key: " .. key),
        },
    }
end

local function graph_contains_path(graph, normalized, path_key)
    for path in pairs(graph.files or {}) do
        if path == normalized or path_util.path_key(path) == path_key then
            return true
        end
    end
    for path in pairs(graph.dependencies or {}) do
        if path == normalized or path_util.path_key(path) == path_key then
            return true
        end
    end
    return false
end

local function project_from_path(opts, policy)
    if policy.source_path ~= true then
        return nil
    end
    local path = opts.path or opts.source_path
    if type(path) ~= "string" or path == "" then
        return nil
    end

    local normalized = path_util.normalize(path)
    if not normalized then
        return nil
    end

    local store = require("typst.project.store")
    local buffer = require("typst.core.buffer")
    local bufnr = buffer.loaded_buffer_for_path(normalized)
    if bufnr then
        local state = store.project_for_buffer(bufnr)
        if state then
            return {
                ok = true,
                project = state,
                bufnr = bufnr,
                source_path = normalized,
            }
        end
    end

    local path_key = path_util.path_key(normalized)
    local services = require("typst.project.services")
    for _, state in pairs(store.all()) do
        if
            state.main == normalized
            or path_util.path_key(state.main) == path_key
        then
            return {
                ok = true,
                project = state,
                source_path = normalized,
            }
        end
        if graph_contains_path(services.graph(state), normalized, path_key) then
            return {
                ok = true,
                project = state,
                source_path = normalized,
            }
        end
    end

    return nil
end

local function source_path_requested(opts, policy)
    if policy.source_path ~= true then
        return nil
    end
    local path = opts.path or opts.source_path
    if type(path) == "string" and path ~= "" then
        return path
    end
    return nil
end

--- Resolve a project for public API wrappers without accidental scratch state.
---@param opts? table|integer Options with `project`/`bufnr`, or a bufnr.
---@param policy? {create?:boolean, require_typst?:boolean, settle_pending?:boolean, operation?:string, passive?:boolean, notify?:boolean, source_path?:boolean, fallback_to_buffer_on_source_miss?:boolean}
---@param notify? fun(message:string, level?:integer)
---@return table ctx `{ ok=true, project=... }` or `{ ok=false, error=... }`.
function M.project(opts, policy, notify)
    policy = policy or {}
    if type(opts) ~= "table" then
        opts = { bufnr = opts }
    else
        opts = opts or {}
    end

    if type(opts.project) == "table" then
        if opts.project.mutable == false then
            local state = require("typst.project.context").live(opts.project)
            if state then
                return { ok = true, project = state }
            end
            local key = opts.project.key
            local err = {
                ok = false,
                reason = "unknown_project_key",
                operation = policy.operation,
                key = key,
                message = ("Unknown Typst project key: %s"):format(
                    tostring(key)
                ),
            }
            maybe_notify(opts, policy, notify, err, vim.log.levels.WARN)
            return { ok = false, error = err }
        end
        return { ok = true, project = opts.project }
    end

    local key_result = project_from_key(opts, policy)
    if key_result then
        if not key_result.ok then
            maybe_notify(
                opts,
                policy,
                notify,
                key_result.error,
                vim.log.levels.WARN
            )
        end
        return key_result
    end

    local path_result = project_from_path(opts, policy)
    if path_result then
        return path_result
    end

    local explicit_source_path = source_path_requested(opts, policy)
    if
        explicit_source_path
        and policy.fallback_to_buffer_on_source_miss ~= true
        and opts.fallback_to_buffer_on_source_miss ~= true
    then
        local bufnr = normalize_bufnr(opts.bufnr)
        local err = no_project(policy.operation, bufnr)
        err.reason = "source_path_not_in_project"
        err.path = explicit_source_path
        err.message = ("No Typst project is attached for source path: %s"):format(
            explicit_source_path
        )
        maybe_notify(opts, policy, notify, err)
        return { ok = false, error = err, bufnr = bufnr }
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local project_context = require("typst.project.context")
    local state = project_context.resolve({
        project = opts.project,
        bufnr = bufnr,
    }, {
        create = false,
        settle_pending = policy.settle_pending == true,
    })
    if state then
        return { ok = true, project = state, bufnr = bufnr }
    end

    if policy.create == true then
        if policy.require_typst == true and not typst_buffer(bufnr) then
            local err = no_project(policy.operation, bufnr)
            maybe_notify(opts, policy, notify, err)
            return { ok = false, error = err, bufnr = bufnr }
        end

        state = project_context.resolve({
            project = opts.project,
            bufnr = bufnr,
        }, {
            create = true,
            settle_pending = policy.settle_pending == true,
        })
        if state then
            return { ok = true, project = state, bufnr = bufnr }
        end
    end

    local err = no_project(policy.operation, bufnr)
    maybe_notify(opts, policy, notify, err)
    return { ok = false, error = err, bufnr = bufnr }
end

return M
