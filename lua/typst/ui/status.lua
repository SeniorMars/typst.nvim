local diagnostics = require("typst.diagnostics")
local compiler = require("typst.compiler")
local count = require("typst.diagnostics.count")
local project = require("typst.project")
local project_store = require("typst.project.store")
local compiler_service = require("typst.project.services.compiler")
local diagnostics_service = require("typst.project.services.diagnostics")
local graph_service = require("typst.project.services.graph")
local index_service = require("typst.project.services.index")
local preview_service = require("typst.project.services.preview")
local resource_session = require("typst.resources.session")
local viewer_service = require("typst.project.services.viewer")
local telemetry = require("typst.core.telemetry")
local semantic_provider = require("typst.integrations.semantic_provider")
local tinymist = require("typst.integrations.tinymist")
local util = require("typst.core.util")

local M = {}

local function copy_list(value)
    return value and vim.deepcopy(value) or nil
end

local function copy_table(value)
    return type(value) == "table" and vim.deepcopy(value) or nil
end

local function process_pid(process)
    if not process then
        return nil
    end

    return process.pid
end

local function watcher_pid(watcher)
    if not watcher or not watcher.handle then
        return nil
    end

    return watcher.handle.pid
end

local function diagnostic_count(state)
    local count = 0
    local namespace = diagnostics.namespace_for(state)
    local diagnostic_state = diagnostics_service.get(state) or {}
    for bufnr in pairs(diagnostic_state.buffers or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            count = count
                + #vim.diagnostic.get(bufnr, { namespace = namespace })
        end
    end
    return count
end

local function provider_status(state)
    local ok, status = pcall(compiler.status, state)
    if ok and type(status) == "string" and status ~= "" then
        return status
    end

    return (compiler_service.get(state) or {}).status
end

local function add_telemetry(snapshot, opts)
    if opts and opts.telemetry then
        snapshot.telemetry = telemetry.snapshot()
        snapshot.telemetry_report = telemetry.report()
    end
    return snapshot
end

function M.snapshot(bufnr, opts)
    bufnr = bufnr or 0
    local resolved_bufnr = bufnr == 0 and vim.api.nvim_get_current_buf()
        or bufnr
    local state = project.get(bufnr)
    if not state then
        return add_telemetry({
            attached = false,
            bufnr = resolved_bufnr,
            status = "detached",
            diagnostics = 0,
            watching = false,
        }, opts)
    end

    local counts = count.buffer(resolved_bufnr)
    local compiler_state = compiler_service.get(state) or {}
    local preview_state = preview_service.get(state) or {}
    local viewer_state = viewer_service.get(state) or {}
    local graph = graph_service.get(state) or {}
    local index_state = index_service.get(state) or {}
    local resources = resource_session.snapshot(state) or {}
    local watcher = compiler_state.watcher
    local output = compiler_state.output

    local semantic_status = semantic_provider.status(state)
    return add_telemetry({
        attached = true,
        bufnr = resolved_bufnr,
        key = state.key,
        root = state.root,
        main = state.main,
        main_name = util.basename(state.main),
        output = output,
        output_name = output and util.basename(output) or nil,
        profile = compiler_state.last_profile,
        status = provider_status(state),
        root_source = state.root_source,
        main_source = state.main_source,
        main_confidence = state.main_confidence,
        main_confidence_source = state.main_confidence_source,
        resolution_pending = state.resolution_pending,
        cwd = compiler_state.last_cwd or state.root,
        command = copy_list(compiler_state.last_command),
        process_pid = process_pid(compiler_state.process),
        watching = watcher ~= nil,
        watcher_pid = watcher_pid(watcher),
        watcher_command = watcher and copy_list(watcher.command) or nil,
        watcher_cwd = watcher and watcher.cwd or nil,
        watcher_compiling = watcher and watcher.currently_compiling == true
            or false,
        watcher_cycle = watcher and watcher.cycle
            or compiler_state.watch_cycle
            or 0,
        watcher_cycle_generation = watcher and watcher.cycle_generation
            or compiler_state.watch_cycle_generation
            or 0,
        watcher_last_cycle_generation = watcher
                and watcher.last_cycle_generation
            or compiler_state.last_cycle_generation,
        watcher_last_cycle = watcher and watcher.last_cycle_status
            or compiler_state.watch_cycle_status,
        watcher_unrecognized_status_lines = watcher
                and watcher.unrecognized_status_lines
            or nil,
        watcher_last_unrecognized_status_line = watcher
                and watcher.last_unrecognized_status_line
            or nil,
        viewer_provider = viewer_state.provider,
        viewer_backend = viewer_state.backend,
        viewer_command = copy_list(viewer_state.command),
        viewer_cwd = viewer_state.cwd,
        preview_backend = preview_state.active and preview_state.active_backend
            or preview_state.last_backend,
        preview_command = preview_state.active and copy_list(
            preview_state.active_command
        ) or copy_list(preview_state.last_command),
        preview_cwd = preview_state.active and preview_state.active_cwd
            or preview_state.last_cwd,
        preview_mode = preview_state.active and preview_state.active_mode
            or preview_state.last_mode,
        preview_active = preview_state.active == true,
        diagnostics = diagnostic_count(state),
        words = counts.words,
        characters = counts.characters,
        characters_with_spaces = counts.characters_with_spaces,
        compiler_diagnostics = diagnostics.policy_state(state),
        semantic_provider = semantic_status.name,
        semantic_provider_mode = semantic_status.mode,
        semantic_provider_backend = semantic_status.backend,
        semantic_provider_enabled = semantic_status.enabled,
        semantic_provider_attached = semantic_status.attached,
        semantic_provider_coc_active = semantic_status.coc_active,
        tinymist_lsp_mode = tinymist.lsp_mode(),
        tinymist_lsp_backend = tinymist.lsp_backend(),
        tinymist_lsp_enabled = tinymist.lsp_enabled(),
        tinymist_lsp_attached = tinymist.available_for_project(state),
        buffers = vim.tbl_count(state.bufs or {}),
        dependencies = vim.tbl_count(graph.dependencies or {}),
        index_generation = index_state.generation or 0,
        index_stats = copy_table(index_state.stats),
        index_fs_watchers = {
            mode = index_state.fs_watch_mode,
            reason = index_state.fs_watch_disabled_reason,
            wanted = index_state.fs_watch_wanted_count,
            active = index_state.fs_watch_active_count,
            cap = index_state.fs_watch_cap,
        },
        resources = resources,
        blockers = copy_table(resources.blockers) or {},
        blocker_count = resources.blocker_count or 0,
    }, opts)
end

function M.project_snapshot(state)
    local bufnr = next(state.bufs or {}) or 0
    local snapshot = M.snapshot(bufnr)
    local compiler_state = compiler_service.get(state) or {}
    local graph = graph_service.get(state) or {}
    local index_state = index_service.get(state) or {}
    local resources = resource_session.snapshot(state) or {}
    local watcher = compiler_state.watcher
    local output = compiler_state.output
    if not snapshot.attached then
        snapshot = {
            attached = true,
            key = state.key,
            root = state.root,
            main = state.main,
            main_name = util.basename(state.main),
            output = output,
            output_name = output and util.basename(output) or nil,
            profile = compiler_state.last_profile,
            status = provider_status(state),
            process_pid = process_pid(compiler_state.process),
            watching = watcher ~= nil,
            watcher_pid = watcher_pid(watcher),
            watcher_compiling = watcher and watcher.currently_compiling == true
                or false,
            diagnostics = diagnostic_count(state),
            buffers = vim.tbl_count(state.bufs or {}),
            dependencies = vim.tbl_count(graph.dependencies or {}),
            index_generation = index_state.generation or 0,
            index_stats = copy_table(index_state.stats),
            index_fs_watchers = {
                mode = index_state.fs_watch_mode,
                reason = index_state.fs_watch_disabled_reason,
                wanted = index_state.fs_watch_wanted_count,
                active = index_state.fs_watch_active_count,
                cap = index_state.fs_watch_cap,
            },
            resources = resources,
            blockers = copy_table(resources.blockers) or {},
            blocker_count = resources.blocker_count or 0,
        }
    end

    snapshot.key = state.key
    snapshot.key_display = project_store.encode_key(state.key)
    snapshot.root = state.root
    snapshot.main = state.main
    snapshot.main_name = util.basename(state.main)
    snapshot.status = provider_status(state)
    snapshot.process_pid = process_pid(compiler_state.process)
    snapshot.watching = watcher ~= nil
    snapshot.watcher_pid = watcher_pid(watcher)
    snapshot.watcher_compiling = watcher and watcher.currently_compiling == true
        or false
    snapshot.watcher_unrecognized_status_lines = watcher
            and watcher.unrecognized_status_lines
        or nil
    snapshot.watcher_last_unrecognized_status_line = watcher
            and watcher.last_unrecognized_status_line
        or nil
    snapshot.diagnostics = diagnostic_count(state)
    snapshot.buffers = vim.tbl_count(state.bufs or {})
    snapshot.dependencies = vim.tbl_count(graph.dependencies or {})
    snapshot.index_generation = index_state.generation or 0
    snapshot.index_stats = copy_table(index_state.stats)
    snapshot.index_fs_watchers = {
        mode = index_state.fs_watch_mode,
        reason = index_state.fs_watch_disabled_reason,
        wanted = index_state.fs_watch_wanted_count,
        active = index_state.fs_watch_active_count,
        cap = index_state.fs_watch_cap,
    }
    snapshot.resources = resources
    snapshot.blockers = copy_table(resources.blockers) or {}
    snapshot.blocker_count = resources.blocker_count or 0
    return snapshot
end

function M.format(snapshot, opts)
    opts = opts or {}
    if not snapshot.attached then
        return opts.detached or ""
    end

    local prefix = opts.prefix or "Typst"
    local parts = { ("%s:%s"):format(prefix, snapshot.status) }

    if opts.main ~= false and snapshot.main_name then
        parts[#parts + 1] = snapshot.main_name
    end

    if opts.profile ~= false and snapshot.profile then
        parts[#parts + 1] = ("[%s]"):format(snapshot.profile)
    end

    if opts.diagnostics ~= false and snapshot.diagnostics > 0 then
        parts[#parts + 1] = ("!%d"):format(snapshot.diagnostics)
    end

    if opts.words and snapshot.words then
        parts[#parts + 1] = ("%dw"):format(snapshot.words)
    end

    if opts.watching ~= false and snapshot.watching then
        parts[#parts + 1] = "watch"
    end

    return table.concat(parts, " ")
end

function M.statusline(opts)
    opts = opts or {}
    return M.format(M.snapshot(opts.bufnr), opts)
end

return M
