local config = require("typst.config")
local log = require("typst.core.log")
local util = require("typst.core.util")
local invalidation = require("typst.project.invalidation")
local services = require("typst.project.services")

local M = {}
local uv = vim.uv or vim.loop
local DISK_SIGNATURE_TTL_MS = 250
local DISK_SIGNATURE_BUDGET = 32
local FS_EVENT_DEBOUNCE_MS = 50
local DEFAULT_FS_WATCHER_CAP = 256
local reset_generation = 0

-- Project index cache state. It tracks three kinds of freshness separately:
-- loaded-buffer ticks, disk signatures for unloaded files, and dependency graph
-- generations. Missing any one of these can make navigation/completion stale.

local function now_ms()
    if uv and type(uv.now) == "function" then
        return uv.now()
    end
    return math.floor(vim.loop.hrtime() / 1000000)
end

local function empty_stats()
    return {
        file_hits = 0,
        file_misses = 0,
        bibliography_hits = 0,
        bibliography_misses = 0,
        collect_hits = 0,
        collect_misses = 0,
    }
end

--- Ensure and return the mutable index cache for a project.
---@param project table Project state whose index service is initialized.
---@return table index Project index cache state.
function M.ensure(project)
    local index = services.index(project) or {}
    index.project = project
    index.files = index.files or {}
    index.bibliographies = index.bibliographies or {}
    index.graph = index.graph or {}
    index.generation = index.generation or 0
    index.config_generation = index.config_generation or config.generation()
    index.buffer_ticks = index.buffer_ticks or {}
    index.file_signatures = index.file_signatures or {}
    index.file_signatures_initialized = index.file_signatures_initialized
        or false
    index.disk_signature_cursor = index.disk_signature_cursor or 1
    index.disk_signature_checked_at = index.disk_signature_checked_at or 0
    index.fs_watchers = index.fs_watchers or {}
    index.fs_watch_generation = index.fs_watch_generation or 0
    index.fs_watch_pending = index.fs_watch_pending or false
    index.fs_watch_mode = index.fs_watch_mode or "idle"
    index.fs_watch_wanted_count = index.fs_watch_wanted_count or 0
    index.fs_watch_active_count = index.fs_watch_active_count or 0
    index.fs_watch_attempted_count = index.fs_watch_attempted_count or 0
    index.fs_watch_failed_count = index.fs_watch_failed_count or 0
    index.fs_watch_first_failed_path = index.fs_watch_first_failed_path or nil
    index.fs_watch_partial = index.fs_watch_partial or false
    index.fs_watch_cap = index.fs_watch_cap or DEFAULT_FS_WATCHER_CAP
    index.stats = index.stats or {}
    for key, value in pairs(empty_stats()) do
        index.stats[key] = index.stats[key] or value
    end
    return index
end

local function close_watcher(record)
    local handle = record and record.handle
    if not handle then
        return
    end

    pcall(function()
        if not handle:is_closing() then
            handle:stop()
            handle:close()
        end
    end)
end

local function close_watchers(project_index)
    for key, record in pairs(project_index.fs_watchers or {}) do
        close_watcher(record)
        project_index.fs_watchers[key] = nil
    end
    project_index.fs_watch_pending = false
end

--- Reset cached index data and file watchers for a project.
---@param project table Project state whose index cache should reset.
function M.reset(project)
    if type(project) ~= "table" then
        return
    end
    reset_generation = reset_generation + 1

    local index = services.index(project)
    if type(index) == "table" then
        close_watchers(index)
    end

    services.graph(project)
    services.ensure(project).index = {
        project = project,
        files = {},
        bibliographies = {},
        graph = {},
        generation = 0,
        config_generation = config.generation(),
        buffer_ticks = {},
        file_signatures = {},
        file_signatures_initialized = false,
        disk_signature_cursor = 1,
        disk_signature_checked_at = 0,
        fs_watchers = {},
        fs_watch_generation = 0,
        fs_watch_pending = false,
        fs_watch_mode = "idle",
        fs_watch_wanted_count = 0,
        fs_watch_active_count = 0,
        fs_watch_attempted_count = 0,
        fs_watch_failed_count = 0,
        fs_watch_first_failed_path = nil,
        fs_watch_partial = false,
        fs_watch_cap = DEFAULT_FS_WATCHER_CAP,
        stats = empty_stats(),
    }
end

--- Increment an index generation and emit the matching invalidation event.
---@param project_index table Project index cache state.
---@param reason string Human-readable freshness reason.
function M.bump(project_index, reason)
    project_index.generation = (project_index.generation or 0) + 1
    project_index.dirty_reason = reason
    if type(project_index.project) == "table" then
        invalidation.emit_reason(project_index.project, reason, {
            index_generation = project_index.generation,
        })
    end
end

local function watched_file_paths(paths)
    local out = {}
    for key, path in pairs(paths or {}) do
        path = type(path) == "string" and path or key
        if type(path) == "string" and path ~= "" then
            local normalized = util.normalize(path)
            if normalized then
                out[util.path_key(normalized)] = normalized
            end
        end
    end
    return out
end

local function watcher_cap()
    local project_config = (config.unsafe_get().project or {}).index or {}
    local setting = project_config.fs_watchers
    if setting == false then
        return false
    end
    if setting == nil or setting == "auto" then
        return DEFAULT_FS_WATCHER_CAP
    end
    return math.floor(tonumber(setting) or DEFAULT_FS_WATCHER_CAP)
end

local function wanted_count(wanted)
    local count = 0
    for _ in pairs(wanted or {}) do
        count = count + 1
    end
    return count
end

local function set_watch_status(project_index, fields)
    for key, value in pairs(fields or {}) do
        project_index[key] = value
    end
end

local function project_store()
    return require("typst.project.store")
end

local function disable_watchers(project_index, reason, wanted_total, cap)
    close_watchers(project_index)
    set_watch_status(project_index, {
        fs_watch_mode = "polling",
        fs_watch_disabled_reason = reason,
        fs_watch_wanted_count = wanted_total,
        fs_watch_active_count = 0,
        fs_watch_attempted_count = 0,
        fs_watch_failed_count = 0,
        fs_watch_first_failed_path = nil,
        fs_watch_partial = false,
        fs_watch_cap = cap,
    })
end

local function warn_cap_exceeded(project_index, wanted_total, cap)
    local key = ("%s:%s"):format(wanted_total, cap)
    if project_index.fs_watch_warning_key == key then
        return
    end
    project_index.fs_watch_warning_key = key
    log.add("warn", "index fs watchers disabled; using disk polling", {
        main = project_index.project and project_index.project.main,
        watched_files = wanted_total,
        cap = cap,
    })
end

local function schedule_watch_bump(project_index, key, path, handle)
    if project_index.fs_watch_pending then
        return
    end

    local project = project_index.project
    local expected_key = project and project.key or nil
    local expected_instance_id = project and project.instance_id or nil
    local expected_reset_generation = reset_generation
    project_index.fs_watch_pending = true
    vim.defer_fn(function()
        project_index.fs_watch_pending = false
        if
            type(project) ~= "table"
            or type(expected_key) ~= "string"
            or project._typst_project_pruned == true
            or project_store().get(expected_key) ~= project
            or project.instance_id ~= expected_instance_id
            or project_index.project ~= project
            or reset_generation ~= expected_reset_generation
        then
            return
        end
        if key ~= nil and handle ~= nil then
            local record = project_index.fs_watchers
                and project_index.fs_watchers[key]
            if not (record and record.handle == handle) then
                return
            end
        end
        -- Filesystem events are coarse and can coalesce writes. Force the next
        -- collection to rebuild disk signatures instead of trusting a cursor.
        project_index.file_signatures_initialized = false
        M.bump(project_index, "disk file changed")
        project_index.last_fs_event_path = path
    end, FS_EVENT_DEBOUNCE_MS)
end

local function start_file_watcher(project_index, key, path)
    if not (uv and type(uv.new_fs_event) == "function") then
        return nil
    end
    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end

    local handle = uv.new_fs_event()
    if not handle then
        return nil
    end
    local started = pcall(function()
        handle:start(path, {}, function(err)
            if err then
                return
            end
            vim.schedule(function()
                local record = project_index.fs_watchers
                    and project_index.fs_watchers[key]
                if record and record.handle == handle then
                    schedule_watch_bump(project_index, key, path, handle)
                end
            end)
        end)
    end)
    if not started then
        close_watcher({ handle = handle })
        return nil
    end

    return {
        handle = handle,
        path = path,
    }
end

--- Synchronize filesystem watchers with the current set of indexed files.
---@param project_index table Project index cache state.
---@param paths table File paths keyed by normalized path or arbitrary id.
function M.sync_file_watchers(project_index, paths)
    if type(project_index) ~= "table" then
        return
    end

    local wanted = watched_file_paths(paths)
    local wanted_total = wanted_count(wanted)
    local cap = watcher_cap()
    local watchers = project_index.fs_watchers or {}
    project_index.fs_watchers = watchers
    project_index.fs_watch_generation = (project_index.fs_watch_generation or 0)
        + 1

    if cap == false then
        disable_watchers(project_index, "disabled", wanted_total, false)
        return
    end

    if wanted_total > cap then
        disable_watchers(project_index, "cap_exceeded", wanted_total, cap)
        warn_cap_exceeded(project_index, wanted_total, cap)
        return
    end

    for key, record in pairs(watchers) do
        if wanted[key] ~= record.path then
            close_watcher(record)
            watchers[key] = nil
        end
    end

    local first_failed_path = nil
    for key, path in pairs(wanted) do
        if not watchers[key] then
            watchers[key] = start_file_watcher(project_index, key, path)
            if not watchers[key] then
                first_failed_path = first_failed_path or path
            end
        end
    end

    local active_count = 0
    for _, record in pairs(watchers) do
        if record then
            active_count = active_count + 1
        end
    end

    set_watch_status(project_index, {
        fs_watch_mode = active_count > 0 and "watching" or "polling",
        fs_watch_disabled_reason = active_count == 0
                and wanted_total > 0
                and "watch_start_failed"
            or nil,
        fs_watch_wanted_count = wanted_total,
        fs_watch_active_count = active_count,
        fs_watch_attempted_count = wanted_total,
        fs_watch_failed_count = math.max(wanted_total - active_count, 0),
        fs_watch_first_failed_path = first_failed_path,
        fs_watch_partial = active_count > 0 and active_count < wanted_total,
        fs_watch_cap = cap,
    })
end

--- Increment one index-cache statistic.
---@param project_index table Project index cache state.
---@param key string Statistic key to increment.
function M.record_hit(project_index, key)
    project_index.stats[key] = (project_index.stats[key] or 0) + 1
end

--- Increment one index-cache statistic by a count.
---@param project_index table Project index cache state.
---@param key string Statistic key to increment.
---@param count? integer Number of hits to add.
function M.record_hits(project_index, key, count)
    if count and count > 0 then
        project_index.stats[key] = (project_index.stats[key] or 0) + count
    end
end

--- Return sorted keys for deterministic cache signatures.
---@param tbl table Table whose keys should be sorted.
---@return any[] keys Sorted key list.
function M.sorted_keys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function add_buffer_tick(ticks, bufnr, path)
    if
        not (
            bufnr
            and vim.api.nvim_buf_is_valid(bufnr)
            and vim.api.nvim_buf_is_loaded(bufnr)
        )
    then
        return
    end

    path = path or vim.api.nvim_buf_get_name(bufnr)
    if not path or path == "" then
        path = ("buffer:%d"):format(bufnr)
    end

    ticks[util.path_key(path)] = vim.api.nvim_buf_get_changedtick(bufnr)
end

--- Capture changedtick values for loaded project/indexed buffers.
---@param project table Project state whose buffers are inspected.
---@param paths table Indexed file paths.
---@param project_buffer_path fun(project:table, bufnr:integer):string? Function resolving project buffer paths.
---@param buffer_map? table Map from path to loaded buffer.
---@return table ticks Changedtick map keyed by normalized path.
function M.current_buffer_ticks(project, paths, project_buffer_path, buffer_map)
    buffer_map = buffer_map or util.loaded_buffers_by_path()
    local ticks = {}
    for bufnr in pairs(project.bufs or {}) do
        add_buffer_tick(ticks, bufnr, project_buffer_path(project, bufnr))
    end

    for key, path in pairs(paths or {}) do
        path = type(path) == "string" and path or key
        if type(path) == "string" then
            local bufnr = util.loaded_buffer_for_path(path, buffer_map)
            if bufnr then
                add_buffer_tick(ticks, bufnr, path)
            end
        end
    end

    return ticks
end

local function same_map(left, right)
    left = left or {}
    right = right or {}

    for key, value in pairs(left) do
        if right[key] ~= value then
            return false
        end
    end

    for key, value in pairs(right) do
        if left[key] ~= value then
            return false
        end
    end

    return true
end

--- Bump index generation when loaded-buffer changedticks differ.
---@param project table Project state whose buffers are inspected.
---@param project_index table Project index cache state.
---@param paths table Indexed file paths.
---@param project_buffer_path fun(project:table, bufnr:integer):string? Function resolving project buffer paths.
---@param buffer_map? table Map from path to loaded buffer.
---@return table ticks Current changedtick map.
function M.sync_buffer_generation(
    project,
    project_index,
    paths,
    project_buffer_path,
    buffer_map
)
    local ticks =
        M.current_buffer_ticks(project, paths, project_buffer_path, buffer_map)
    if not same_map(ticks, project_index.buffer_ticks) then
        project_index.buffer_ticks = ticks
        M.bump(project_index, "buffer changed")
    end
    return ticks
end

local function file_signature(path)
    local stat = type(path) == "string" and uv.fs_stat(path) or nil
    if not stat then
        return "missing"
    end
    return ("file:%d:%d:%d"):format(
        stat.size or 0,
        (stat.mtime and stat.mtime.sec) or 0,
        (stat.mtime and stat.mtime.nsec) or 0
    )
end

--- Capture disk signatures for indexed files that are not loaded in buffers.
---@param paths table Indexed file paths.
---@param buffer_map? table Map from path to loaded buffer.
---@return table signatures File signature map keyed by normalized path.
function M.current_file_signatures(paths, buffer_map)
    buffer_map = buffer_map or util.loaded_buffers_by_path()
    local signatures = {}
    for key, path in pairs(paths or {}) do
        path = type(path) == "string" and path or key
        if type(path) == "string" then
            local bufnr = util.loaded_buffer_for_path(path, buffer_map)
            if not bufnr then
                signatures[util.path_key(path)] = file_signature(path)
            end
        end
    end
    return signatures
end

local function copy_signatures(signatures)
    local out = {}
    for key, value in pairs(signatures or {}) do
        out[key] = value
    end
    return out
end

--- Bump index generation when unloaded-file disk signatures differ.
---@param project_index table Project index cache state.
---@param paths table Indexed file paths.
---@param buffer_map? table Map from path to loaded buffer.
---@param opts? table Sync options; `full=true` checks all unloaded files.
---@return table signatures Current file signature map.
function M.sync_file_generation(project_index, paths, buffer_map, opts)
    opts = opts or {}
    local path_count = vim.tbl_count(paths or {})
    local full = opts.full == true
        or not project_index.file_signatures_initialized
    local due = project_index.disk_signature_checked_at == nil
        or path_count <= DISK_SIGNATURE_BUDGET
        or now_ms()
            >= (project_index.disk_signature_checked_at + DISK_SIGNATURE_TTL_MS)

    if not full and not due then
        return project_index.file_signatures
    end

    local signatures
    if full then
        signatures = M.current_file_signatures(paths, buffer_map)
    else
        -- Large projects can call the index often from completion/navigation.
        -- Check a bounded slice of unloaded files per pass and rotate the cursor
        -- so disk changes are noticed without stat-ing every dependency.
        signatures = copy_signatures(project_index.file_signatures)
        local keys = M.sorted_keys(paths or {})
        local total = #keys
        local cursor = math.max(
            1,
            math.min(project_index.disk_signature_cursor or 1, total)
        )
        local checked = 0
        while total > 0 and checked < math.min(DISK_SIGNATURE_BUDGET, total) do
            local key = keys[cursor]
            local path = paths[key]
            path = type(path) == "string" and path or key
            local signature_key = util.path_key(path)
            if util.loaded_buffer_for_path(path, buffer_map) then
                signatures[signature_key] = nil
            else
                signatures[signature_key] = file_signature(path)
            end
            cursor = cursor + 1
            if cursor > total then
                cursor = 1
            end
            checked = checked + 1
        end
        project_index.disk_signature_cursor = cursor
    end

    project_index.disk_signature_checked_at = now_ms()
    project_index.file_signatures_initialized = true
    if not same_map(signatures, project_index.file_signatures) then
        project_index.file_signatures = signatures
        M.bump(project_index, "disk file changed")
    end
    return signatures
end

--- Bump index generation when global config generation changes.
---@param project_index table Project index cache state.
function M.sync_config_generation(project_index)
    local generation = config.generation()
    if project_index.config_generation ~= generation then
        project_index.config_generation = generation
        project_index.file_signatures_initialized = false
        M.bump(project_index, "config changed")
    end
end

--- Build a deterministic signature for project dependency graph freshness.
---@param project table Project state whose graph service is inspected.
---@return string signature Dependency graph signature.
function M.dependency_signature(project)
    local graph_dependencies = require("typst.project.graph.dependencies")
    local graph_sources = require("typst.project.graph.sources")
    local parts = {
        "main",
        project.main or "",
        "root",
        project.root or "",
        "dependencies",
    }

    for _, path in ipairs(M.sorted_keys(graph_dependencies.get(project))) do
        parts[#parts + 1] = path
    end

    parts[#parts + 1] = "files"
    for _, path in ipairs(M.sorted_keys(graph_sources.get(project))) do
        parts[#parts + 1] = path
    end

    return table.concat(parts, "\n")
end

--- Bump index generation when project dependency graph signature changes.
---@param project table Project state whose graph is inspected.
---@param project_index table Project index cache state.
function M.sync_dependency_generation(project, project_index)
    local signature = M.dependency_signature(project)
    if project_index.dependency_signature ~= signature then
        project_index.dependency_signature = signature
        M.bump(project_index, "dependency graph changed")
    end
end

M._schedule_watch_bump_for_tests = function(project_index, path)
    return schedule_watch_bump(project_index, nil, path, nil)
end
M._reset_generation_for_tests = function()
    return reset_generation
end

return M
