local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr
local path_util = require("typst.core.path")

local maybe_notify

local function notify_level(policy, fallback)
    local level = policy and policy.notify_level
    if level == "error" then
        return vim.log.levels.ERROR
    end
    if level == "warn" then
        return vim.log.levels.WARN
    end
    if level == "info" then
        return vim.log.levels.INFO
    end
    if type(level) == "number" then
        return level
    end
    return fallback
end

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

local function unresolved_import_scan_resolution(resolution)
    if type(resolution) ~= "table" then
        return false
    end
    return resolution.resolution_pending == "import_scan"
        or resolution.import_scan_pending == true
        or type(resolution.import_scan_suggestion) == "table"
end

local function resolution_path_matches(resolution, normalized, path_key)
    if type(resolution) ~= "table" or type(normalized) ~= "string" then
        return false
    end
    local buffer = type(resolution.buffer) == "string"
            and path_util.normalize(resolution.buffer)
        or nil
    return buffer == normalized
        or (buffer ~= nil and path_util.path_key(buffer) == path_key)
end

local function import_scan_resolution(
    state,
    bufnr,
    allow_project_level,
    source_path
)
    if type(state) ~= "table" then
        return nil, nil
    end
    if type(bufnr) == "number" and bufnr > 0 then
        local resolution = state.resolutions and state.resolutions[bufnr] or nil
        if type(resolution) == "table" then
            return resolution, bufnr
        end
        if allow_project_level ~= true then
            return nil, nil
        end
    end
    local normalized_source = type(source_path) == "string"
            and path_util.normalize(source_path)
        or nil
    local source_key = normalized_source
            and path_util.path_key(normalized_source)
        or nil
    if normalized_source then
        for owner_bufnr, resolution in pairs(state.resolutions or {}) do
            if
                resolution_path_matches(
                    resolution,
                    normalized_source,
                    source_key
                )
            then
                return resolution, owner_bufnr
            end
        end
    end
    if allow_project_level == true then
        local matches = {}
        for owner_bufnr, resolution in pairs(state.resolutions or {}) do
            if unresolved_import_scan_resolution(resolution) then
                matches[#matches + 1] = {
                    bufnr = owner_bufnr,
                    resolution = resolution,
                }
            end
        end
        if #matches == 1 then
            return matches[1].resolution, matches[1].bufnr
        end
        if #matches > 1 then
            return nil, nil, "ambiguous"
        end
        if state.resolution_pending == "import_scan" then
            return nil, nil, "pending"
        end
    end
    return nil, nil
end

local function import_scan_pending(
    state,
    bufnr,
    allow_project_level,
    source_path
)
    if type(state) ~= "table" or type(bufnr) ~= "number" or bufnr <= 0 then
        return allow_project_level == true
                and state
                and state.resolution_pending == "import_scan"
            or false
    end
    local resolution, _, status =
        import_scan_resolution(state, bufnr, allow_project_level, source_path)
    if status == "ambiguous" or status == "pending" then
        return true
    end
    if type(resolution) == "table" then
        return resolution.resolution_pending == "import_scan"
            or resolution.import_scan_pending == true
    end
    return state.resolution_pending == "import_scan"
        and state.bufs
        and state.bufs[bufnr] == true
end

local function import_scan_suggestion_ready(
    state,
    bufnr,
    allow_project_level,
    source_path
)
    local resolution =
        import_scan_resolution(state, bufnr, allow_project_level, source_path)
    local suggestion = resolution and resolution.import_scan_suggestion
    return type(suggestion) == "table"
        and type(suggestion.main) == "string"
        and suggestion.main ~= ""
end

local function import_scan_unsettled(
    state,
    bufnr,
    allow_project_level,
    source_path
)
    return import_scan_pending(state, bufnr, allow_project_level, source_path)
        or import_scan_suggestion_ready(
            state,
            bufnr,
            allow_project_level,
            source_path
        )
end

local function command_wait_ms(opts)
    if opts.import_scan_command_wait_ms ~= nil then
        return tonumber(opts.import_scan_command_wait_ms) or 0
    end

    local ok, config = pcall(require, "typst.config")
    if ok then
        local current = config.unsafe_get()
        return tonumber(
            current
                and current.project
                and current.project.import_scan_command_wait_ms
        ) or 0
    end
    return 0
end

local function wait_for_import_scan(
    state,
    bufnr,
    timeout_ms,
    allow_project_level,
    source_path
)
    timeout_ms = math.max(0, tonumber(timeout_ms) or 0)
    if timeout_ms <= 0 then
        return
    end

    local store = require("typst.project.store")
    local _, owner_bufnr =
        import_scan_resolution(state, bufnr, allow_project_level, source_path)
    owner_bufnr = owner_bufnr or bufnr
    local key = state and state.key
    vim.wait(timeout_ms, function()
        local current = owner_bufnr and store.project_for_buffer(owner_bufnr)
            or nil
        if not current and key then
            current = store.get(key)
        end
        if not current then
            return true
        end
        return import_scan_suggestion_ready(
            current,
            owner_bufnr,
            allow_project_level,
            source_path
        ) or not import_scan_pending(
            current,
            owner_bufnr,
            allow_project_level,
            source_path
        )
    end, 10, false)
end

local function pending_resolution_error(policy, bufnr, state, wait_ms)
    return {
        ok = false,
        reason = "resolution_pending",
        operation = policy.operation,
        bufnr = bufnr,
        project_key = state and state.key or nil,
        main = state and state.main or nil,
        wait_ms = wait_ms,
        message = "Deferred Typst import scan is still running; set a main file, retry, or pass accept_pending_resolution=true.",
    }
end

local function ambiguous_resolution_error(policy, bufnr, state, wait_ms)
    return {
        ok = false,
        reason = "resolution_ambiguous",
        operation = policy.operation,
        bufnr = bufnr,
        project_key = state and state.key or nil,
        main = state and state.main or nil,
        wait_ms = wait_ms,
        message = "Multiple buffers have pending Typst import-scan suggestions; pass bufnr or source_path.",
    }
end

local function maybe_block_pending_resolution(
    opts,
    policy,
    notify,
    state,
    bufnr,
    allow_project_level
)
    local source_path = opts.source_path or opts.path
    if
        policy.block_pending_resolution ~= true
        or opts.accept_pending_resolution == true
        or not import_scan_unsettled(
            state,
            bufnr,
            allow_project_level,
            source_path
        )
    then
        return nil
    end

    local wait_ms = command_wait_ms(opts)
    wait_for_import_scan(
        state,
        bufnr,
        wait_ms,
        allow_project_level,
        source_path
    )

    local project_context = require("typst.project.context")
    local _, owner_bufnr, resolution_status =
        import_scan_resolution(state, bufnr, allow_project_level, source_path)
    if resolution_status == "ambiguous" then
        local err = ambiguous_resolution_error(policy, bufnr, state, wait_ms)
        maybe_notify(opts, policy, notify, err, vim.log.levels.WARN)
        return { ok = false, error = err, bufnr = bufnr }
    end
    owner_bufnr = owner_bufnr or bufnr
    local resolved = project_context.resolve({
        bufnr = owner_bufnr,
    }, {
        create = false,
        settle_pending = true,
    })
    if
        resolved
        and not import_scan_unsettled(
            resolved,
            owner_bufnr,
            allow_project_level,
            source_path
        )
    then
        return { ok = true, project = resolved, bufnr = owner_bufnr }
    end

    local _, _, final_status = import_scan_resolution(
        resolved or state,
        owner_bufnr,
        allow_project_level,
        source_path
    )
    if final_status == "ambiguous" then
        local err = ambiguous_resolution_error(
            policy,
            owner_bufnr,
            resolved or state,
            wait_ms
        )
        maybe_notify(opts, policy, notify, err, vim.log.levels.WARN)
        return { ok = false, error = err, bufnr = owner_bufnr }
    end

    local err = pending_resolution_error(
        policy,
        owner_bufnr,
        resolved or state,
        wait_ms
    )
    maybe_notify(opts, policy, notify, err, vim.log.levels.WARN)
    return { ok = false, error = err, bufnr = owner_bufnr }
end

local function should_notify(opts, policy)
    if opts.notify ~= nil then
        return opts.notify == true
    end
    if policy and policy.notify ~= nil then
        return policy.notify == true
    end
    return not policy or policy.passive ~= true
end

function maybe_notify(opts, policy, notify, err, level)
    if should_notify(opts, policy) and type(notify) == "function" then
        notify(err.message, notify_level(policy, level or vim.log.levels.WARN))
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
            key_display = key,
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

local function source_path_match_summary(state, store)
    return {
        key = state.key,
        key_display = store.encode_key(state.key),
        root = state.root,
        main = state.main,
    }
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
    local matches = {}
    local seen = {}
    local function add_match(state)
        if type(state) ~= "table" or type(state.key) ~= "string" then
            return
        end
        if seen[state.key] then
            return
        end
        seen[state.key] = true
        matches[#matches + 1] = state
    end

    local bufnr = buffer.loaded_buffer_for_path(normalized)
    if bufnr then
        local state = store.project_for_buffer(bufnr)
        if state then
            add_match(state)
        end
    end

    local path_key = path_util.path_key(normalized)
    local services = require("typst.project.services")
    for _, state in pairs(store.all()) do
        if
            state.main == normalized
            or path_util.path_key(state.main) == path_key
        then
            add_match(state)
        elseif
            graph_contains_path(services.graph(state), normalized, path_key)
        then
            add_match(state)
        end
    end

    if #matches == 1 then
        return {
            ok = true,
            project = matches[1],
            bufnr = bufnr,
            source_path = normalized,
        }
    end

    if #matches > 1 then
        table.sort(matches, function(left, right)
            return tostring(left.key) < tostring(right.key)
        end)
        local summaries = {}
        for _, state in ipairs(matches) do
            summaries[#summaries + 1] = source_path_match_summary(state, store)
        end
        return {
            ok = false,
            error = {
                ok = false,
                reason = "ambiguous_source_path",
                operation = policy.operation,
                path = normalized,
                matches = summaries,
                message = ("Source path belongs to multiple Typst projects; pass project/key explicitly: %s"):format(
                    normalized
                ),
            },
            source_path = normalized,
        }
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
        opts = opts == nil and {} or { bufnr = opts }
    end

    local bufnr = normalize_bufnr(opts and opts.bufnr or nil)

    if type(opts.project) == "table" then
        if opts.project.mutable == false then
            local state = require("typst.project.context").live(opts.project)
            if state then
                local pending = maybe_block_pending_resolution(
                    opts,
                    policy,
                    notify,
                    state,
                    bufnr,
                    true
                )
                if pending then
                    return pending
                end
                return { ok = true, project = state }
            end
            local key = opts.project.key
            local err = {
                ok = false,
                reason = "unknown_project_key",
                operation = policy.operation,
                key = key,
                key_display = key,
                message = ("Unknown Typst project key: %s"):format(
                    tostring(key)
                ),
            }
            maybe_notify(opts, policy, notify, err, vim.log.levels.WARN)
            return { ok = false, error = err }
        end
        local pending = maybe_block_pending_resolution(
            opts,
            policy,
            notify,
            opts.project,
            bufnr,
            true
        )
        if pending then
            return pending
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
        else
            local pending = maybe_block_pending_resolution(
                opts,
                policy,
                notify,
                key_result.project,
                bufnr,
                true
            )
            if pending then
                return pending
            end
        end
        return key_result
    end

    local path_result = project_from_path(opts, policy)
    if path_result then
        if not path_result.ok then
            maybe_notify(
                opts,
                policy,
                notify,
                path_result.error,
                vim.log.levels.WARN
            )
            return path_result
        end
        local pending = maybe_block_pending_resolution(
            opts,
            policy,
            notify,
            path_result.project,
            path_result.bufnr or bufnr,
            path_result.bufnr == nil
        )
        if pending then
            return pending
        end
        return path_result
    end

    local explicit_source_path = source_path_requested(opts, policy)
    if
        explicit_source_path
        and policy.fallback_to_buffer_on_source_miss ~= true
        and opts.fallback_to_buffer_on_source_miss ~= true
    then
        local err = no_project(policy.operation, bufnr)
        err.reason = "source_path_not_in_project"
        err.path = explicit_source_path
        err.message = ("No Typst project is attached for source path: %s"):format(
            explicit_source_path
        )
        maybe_notify(opts, policy, notify, err)
        return { ok = false, error = err, bufnr = bufnr }
    end

    local project_context = require("typst.project.context")
    local state = project_context.resolve({
        project = opts.project,
        bufnr = bufnr,
    }, {
        create = false,
        settle_pending = policy.settle_pending == true,
    })
    if state then
        local pending =
            maybe_block_pending_resolution(opts, policy, notify, state, bufnr)
        if pending then
            return pending
        end
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
            local pending = maybe_block_pending_resolution(
                opts,
                policy,
                notify,
                state,
                bufnr
            )
            if pending then
                return pending
            end
            return { ok = true, project = state, bufnr = bufnr }
        end
    end

    local err = no_project(policy.operation, bufnr)
    maybe_notify(opts, policy, notify, err)
    return { ok = false, error = err, bufnr = bufnr }
end

---Resolve runtime endpoint project context from its declarative policy.
---@param endpoint table Runtime endpoint policy.
---@param opts? table|integer Runtime call options.
---@param notify? fun(message:string, level?:integer)
---@return table ctx Resolved endpoint context.
function M.resolve_endpoint(endpoint, opts, notify)
    opts = opts or {}
    local project_policy = endpoint and endpoint.project or nil
    if project_policy == false or project_policy == nil then
        return {
            ok = true,
            opts = type(opts) == "table" and opts or { bufnr = opts },
            endpoint = endpoint,
            policy = project_policy,
        }
    end

    local policy = vim.tbl_extend("force", project_policy, {
        operation = project_policy.operation
            or (endpoint and endpoint.operation)
            or nil,
    })
    local ctx = M.project(opts, policy, notify)
    if not ctx.ok then
        ctx.opts = type(opts) == "table" and opts or { bufnr = opts }
        ctx.endpoint = endpoint
        ctx.policy = policy
        return ctx
    end
    ctx.opts = type(opts) == "table" and opts or { bufnr = opts }
    ctx.endpoint = endpoint
    ctx.policy = policy
    return ctx
end

return M
