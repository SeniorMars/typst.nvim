local M = {}

local config = require("typst.config")
local log = require("typst.core.log")
local main_file = require("typst.project.main_file")
local project = require("typst.project")
local project_model = require("typst.project.model")
local resource_manager = require("typst.runtime.resource_manager")
local root_discovery = require("typst.project.root")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local deferred_import_scan_tokens = {}
local deferred_import_scan_handles = {}
local next_deferred_import_scan_token = 0

local function buffer_path(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local path = vim.api.nvim_buf_get_name(bufnr)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return util.normalize(path)
end

local function clear_deferred_import_scan(state, bufnr, token, status)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
    if not resolution or resolution.import_scan_token ~= token then
        return
    end
    for _, entry in ipairs(resolution.trace or {}) do
        if entry.stage == "import_scan" and entry.status == "deferred" then
            entry.status = status or "finished"
            entry.settled = true
            break
        end
    end

    resolution.import_scan_pending = false
    resolution.resolution_pending = nil
    resolution.import_scan_request = nil
    resolution.import_scan_token = nil
    resolution.import_scan_epoch_token = nil
    resolution.import_scan_status = status or "finished"
    project_model.refresh_resolution_pending(state)
end

local function clear_deferred_import_scan_local(bufnr, token)
    if deferred_import_scan_tokens[bufnr] ~= token then
        return false
    end
    deferred_import_scan_tokens[bufnr] = nil
    deferred_import_scan_handles[bufnr] = nil
    return true
end

local function finish_deferred_import_scan(bufnr, token, state, status)
    clear_deferred_import_scan_local(bufnr, token)
    clear_deferred_import_scan(state, bufnr, token, status)
end

--- Cancel lifecycle-local import scan work for a buffer.
---@param bufnr integer
---@param reason? string
---@param state? table
function M.cancel(bufnr, reason, state)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
    local token = deferred_import_scan_tokens[bufnr]
        or (resolution and resolution.import_scan_token)
    local handle = deferred_import_scan_handles[bufnr]
    if token ~= nil then
        clear_deferred_import_scan(state, bufnr, token, reason or "cancelled")
    end
    deferred_import_scan_handles[bufnr] = nil
    deferred_import_scan_tokens[bufnr] = nil
    if type(handle) == "table" and handle.pending == true then
        pcall(handle.cancel, handle, { reason = reason or "cancelled" })
    end
end

--- Cancel every lifecycle-local deferred import scan.
---@param reason? string
function M.cancel_all(reason)
    local bufnrs = {}
    for bufnr in pairs(deferred_import_scan_tokens) do
        bufnrs[#bufnrs + 1] = bufnr
    end
    for bufnr in pairs(deferred_import_scan_handles) do
        if deferred_import_scan_tokens[bufnr] == nil then
            bufnrs[#bufnrs + 1] = bufnr
        end
    end
    for _, bufnr in ipairs(bufnrs) do
        M.cancel(bufnr, reason)
    end
    deferred_import_scan_tokens = {}
    deferred_import_scan_handles = {}
end

---@param state? table
---@param bufnr integer
---@return table? suggestion
---@return table? resolution
function M.suggestion(state, bufnr)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
    local suggestion = resolution and resolution.import_scan_suggestion
    if
        type(suggestion) == "table"
        and type(suggestion.main) == "string"
        and suggestion.main ~= ""
    then
        return suggestion, resolution
    end
end

local function record_import_scan_suggestion(state, bufnr, token, result)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
    if not resolution or resolution.import_scan_token ~= token then
        return false
    end

    local suggestion = {
        main = result.main,
        main_source = result.main_source or "import scan",
        root = result.root or state.root,
        root_source = result.root_source or "import scan root",
        confidence = main_file.confidence_for_source(
            result.main_source or "import scan"
        ),
    }
    resolution.import_scan_suggestion = suggestion
    local updated_trace = false
    for _, entry in ipairs(resolution.trace or {}) do
        if entry.stage == "import_scan" then
            entry.status = "suggested"
            entry.settled = true
            entry.main = suggestion.main
            entry.source = suggestion.main_source
            entry.root = suggestion.root
            entry.root_source = suggestion.root_source
            entry.confidence = suggestion.confidence
            updated_trace = true
            break
        end
    end
    if not updated_trace then
        resolution.trace = resolution.trace or {}
        resolution.trace[#resolution.trace + 1] = {
            stage = "import_scan",
            status = "suggested",
            settled = true,
            main = suggestion.main,
            source = suggestion.main_source,
            root = suggestion.root,
            root_source = suggestion.root_source,
            confidence = suggestion.confidence,
            line_limit = root_discovery.import_scan_line_limit(),
        }
    end
    resolution.import_scan_pending = false
    resolution.resolution_pending = nil
    resolution.import_scan_request = nil
    resolution.import_scan_token = nil
    resolution.import_scan_epoch_token = nil
    resolution.import_scan_status = "suggested"
    project_model.refresh_resolution_pending(state)
    return true
end

--- Start deferred import scan work for a just-attached buffer.
---@param bufnr integer
---@param state table
---@param candidate? table
function M.schedule(bufnr, state, candidate)
    local resolution = candidate and candidate.resolution or nil
    local request = resolution and resolution.import_scan_request or nil
    if type(request) ~= "table" then
        return
    end

    M.cancel(bufnr, "rescheduled", state)
    next_deferred_import_scan_token = next_deferred_import_scan_token + 1
    local token = next_deferred_import_scan_token
    local epoch_token = resource_manager.token(state, "import_scan")
    deferred_import_scan_tokens[bufnr] = token

    local stored_resolution = state.resolutions and state.resolutions[bufnr]
    if stored_resolution then
        stored_resolution.import_scan_token = token
        stored_resolution.import_scan_epoch_token = epoch_token
    end

    local expected_key = state.key
    local expected_path = request.path
    local expected_config_generation = request.config_generation
        or config.generation()
    vim.defer_fn(function()
        if deferred_import_scan_tokens[bufnr] ~= token then
            return
        end
        local epoch_valid, epoch_reason =
            resource_manager.valid_token(epoch_token)

        local current = project.get(bufnr)
        local function clear_current(status)
            finish_deferred_import_scan(bufnr, token, current, status)
        end

        if not epoch_valid then
            clear_current(epoch_reason or "stale")
            return
        end

        if expected_config_generation ~= config.generation() then
            clear_current("config_changed")
            return
        end

        if not current then
            finish_deferred_import_scan(bufnr, token, nil, "missing_project")
            return
        end

        local current_path = buffer_path(bufnr)
        if
            not current_path or not util.same_path(current_path, expected_path)
        then
            clear_current("path_changed")
            return
        end

        if current.key ~= expected_key then
            clear_current("project_changed")
            return
        end

        local current_resolution = current.resolutions
                and current.resolutions[bufnr]
            or nil
        if not current_resolution then
            finish_deferred_import_scan(
                bufnr,
                token,
                current,
                "missing_resolution"
            )
            project_model.refresh_resolution_pending(current)
            return
        end

        if current_resolution.import_scan_token ~= token then
            return
        end

        local scan_started = telemetry.start()
        local ok_handle, handle = pcall(
            root_discovery.import_scan_main_async,
            request.path,
            request.root,
            request.root_source,
            config.unsafe_get(),
            { mode = "deferred" }
        )
        if not ok_handle then
            finish_deferred_import_scan(bufnr, token, current, "failed")
            telemetry.finish("project.deferred_import_scan", scan_started, {
                ok = false,
                bufnr = bufnr,
                project_key = expected_key,
                root = request.root,
                mode = "deferred",
                abort_reason = "startup_error",
            })
            log.add("warn", "deferred import scan failed to start", {
                bufnr = bufnr,
                path = request.path,
                error = tostring(handle),
            })
            return
        end
        if type(handle) ~= "table" then
            finish_deferred_import_scan(bufnr, token, current, "disabled")
            telemetry.finish("project.deferred_import_scan", scan_started, {
                ok = false,
                bufnr = bufnr,
                project_key = expected_key,
                root = request.root,
                mode = "deferred",
                abort_reason = "disabled",
            })
            return
        end
        deferred_import_scan_handles[bufnr] = handle
        handle:on_finish(function(result)
            if deferred_import_scan_tokens[bufnr] ~= token then
                return
            end
            clear_deferred_import_scan_local(bufnr, token)

            local scan_stats = root_discovery._import_scan_stats()
            telemetry.finish("project.deferred_import_scan", scan_started, {
                ok = type(result) == "table" and result.ok ~= false,
                bufnr = bufnr,
                project_key = expected_key,
                root = request.root,
                mode = scan_stats.last_mode,
                files = scan_stats.last_files,
                dirs = scan_stats.last_dirs,
                reads = scan_stats.reads,
                abort_reason = scan_stats.last_abort_reason,
            })

            local finished_current = project.get(bufnr)
            local epoch_current, epoch_reason =
                resource_manager.valid_token(epoch_token)
            if not finished_current or finished_current.key ~= expected_key then
                clear_deferred_import_scan(
                    finished_current,
                    bufnr,
                    token,
                    "project_changed"
                )
                return
            end
            if expected_config_generation ~= config.generation() then
                clear_deferred_import_scan(
                    finished_current,
                    bufnr,
                    token,
                    "config_changed"
                )
                return
            end
            if not epoch_current then
                clear_deferred_import_scan(
                    finished_current,
                    bufnr,
                    token,
                    epoch_reason or "stale"
                )
                return
            end
            local current_path = buffer_path(bufnr)
            if
                not current_path
                or not util.same_path(current_path, expected_path)
            then
                clear_deferred_import_scan(
                    finished_current,
                    bufnr,
                    token,
                    "path_changed"
                )
                return
            end

            if type(result) ~= "table" or result.ok == false then
                clear_deferred_import_scan(
                    finished_current,
                    bufnr,
                    token,
                    result and result.status or "failed"
                )
                log.add("warn", "deferred import scan failed", {
                    bufnr = bufnr,
                    path = request.path,
                    error = result and result.error or result,
                })
                return
            end

            if not result.found or not result.main then
                clear_deferred_import_scan(
                    finished_current,
                    bufnr,
                    token,
                    result.status or "not_found"
                )
                return
            end

            if
                record_import_scan_suggestion(
                    finished_current,
                    bufnr,
                    token,
                    result
                )
            then
                log.add("info", "deferred import scan suggested Typst main", {
                    bufnr = bufnr,
                    path = request.path,
                    main = result.main,
                    root = result.root,
                })
            end
        end)
    end, 20)
end

--- Accept a recorded import-scan suggestion during explicit project lookup.
---@param bufnr integer
---@param previous table
---@param suggestion table
---@param resolution? table
---@return table? state
function M.consume(bufnr, previous, suggestion, resolution)
    local path = buffer_path(bufnr)
    if not path then
        return nil
    end
    local resolution_buffer = resolution and resolution.buffer
    if
        type(resolution_buffer) == "string"
        and resolution_buffer ~= ""
        and not util.same_path(path, resolution_buffer)
    then
        resolution.import_scan_suggestion = nil
        return nil
    end

    local trace = vim.deepcopy(resolution and resolution.trace or {})
    for _, entry in ipairs(trace) do
        if entry.stage == "import_scan" then
            entry.status = "accepted"
            entry.settled = true
            entry.main = suggestion.main
            entry.source = suggestion.main_source or "import scan"
            entry.root = suggestion.root or previous.root
            entry.root_source = suggestion.root_source or "import scan root"
            entry.confidence = suggestion.confidence
                or main_file.confidence_for_source(
                    suggestion.main_source or "import scan"
                )
            break
        end
    end

    local next_resolution = vim.deepcopy(resolution or {})
    next_resolution.root_source = suggestion.root_source or "import scan root"
    next_resolution.main_source = suggestion.main_source or "import scan"
    next_resolution.main_confidence = suggestion.confidence
        or main_file.confidence_for_source(
            suggestion.main_source or "import scan"
        )
    next_resolution.main_confidence_source = suggestion.main_source
        or "import scan"
    next_resolution.resolution_pending = nil
    next_resolution.import_scan_pending = false
    next_resolution.import_scan_request = nil
    next_resolution.import_scan_token = nil
    next_resolution.import_scan_epoch_token = nil
    next_resolution.import_scan_status = "accepted"
    next_resolution.import_scan_suggestion = nil
    next_resolution.import_scan_line_limit =
        root_discovery.import_scan_line_limit()
    next_resolution.trace = trace

    local commit_ok, state = pcall(project.commit_attach, {
        bufnr = bufnr,
        path = path,
        root = suggestion.root or previous.root,
        main = suggestion.main,
        previous_key = previous.key,
        resolution = next_resolution,
    })
    if not commit_ok then
        log.add("warn", "failed to accept deferred import-scan suggestion", {
            bufnr = bufnr,
            path = path,
            main = suggestion.main,
            error = state,
        })
        return nil
    end
    return state
end

--- Clear lifecycle-local deferred resolver state.
---@param reason? string
function M.reset(reason)
    M.cancel_all(reason or "lifecycle_reset")
    next_deferred_import_scan_token = 0
end

function M.state()
    return {
        tokens = vim.deepcopy(deferred_import_scan_tokens),
        handles = vim.deepcopy(deferred_import_scan_handles),
    }
end

return M
