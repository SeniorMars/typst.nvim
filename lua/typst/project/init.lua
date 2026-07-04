local config = require("typst.config")
local context = require("typst.project.context")
local log = require("typst.core.log")
local dependencies = require("typst.project.dependencies")
local diagnostics = require("typst.diagnostics")
local graph_sources = require("typst.project.graph.sources")
local project_model = require("typst.project.model")
local project_resolver = require("typst.project.resolver")
local compiler_service = require("typst.project.services.compiler")
local root_discovery = require("typst.project.root")
local state_store = require("typst.core.state")
local project_store = require("typst.project.store")
local util = require("typst.core.util")

local M = {}

-- Project ownership for Typst buffers.
--
-- A project is keyed by both root and main file because a single directory can
-- contain multiple documents, and a single Neovim session can edit several of
-- them at once. Buffer membership is tracked separately so moving a buffer to a
-- new main can detach diagnostics and compiler state from the old project.

local project_key = project_store.project_key
local normalize_bufnr = project_model.normalize_bufnr
local current_buffer_path = project_model.current_buffer_path
local rebuild_files = project_model.rebuild_files

---@param project TypstProject Project whose buffer resolution is recorded.
---@param bufnr integer Buffer number.
---@param path string Buffer path.
---@param resolution? table Resolution metadata.
local function record_resolution(project, bufnr, path, resolution)
    resolution = vim.tbl_extend("force", {
        buffer = path,
        root_source = "unknown",
        main_source = "unknown",
    }, resolution or {})

    project.resolutions[bufnr] = resolution
    project.last_resolution = resolution
    project.root_source = resolution.root_source
    project.main_source = resolution.main_source
    project.main_confidence = resolution.main_confidence
    project.main_confidence_source = resolution.main_confidence_source
    project_model.refresh_resolution_pending(project)
end

local function transfer_buffer(bufnr, next_key)
    local previous_key = project_store.key_for_buffer(bufnr)
    if previous_key == nil or previous_key == next_key then
        return
    end

    require("typst.project.attachments").forget(bufnr, previous_key)
    local previous = project_store.get(previous_key)
    if previous then
        previous.bufs[bufnr] = nil
        diagnostics.clear_buffer(previous, bufnr, { emit = false })
        previous.resolutions[bufnr] = nil
        project_model.refresh_resolution_pending(previous)
        log.add("info", "moved buffer to another project", {
            bufnr = bufnr,
            from = previous.main,
            to = next_key,
        })
        rebuild_files(previous)
        project_store.prune_if_empty(previous, "buffer moved")
    end
end

---@param root string Project root.
---@param main string Project main file.
---@param bufnr integer Attached buffer.
---@param path string Attached buffer path.
---@param resolution? table Resolution metadata.
---@return TypstProject project Attached project state.
local function create_or_update(root, main, bufnr, path, resolution)
    local key = project_key(root, main)
    local project = project_store.create(root, main)
    local buffer_is_scratch = type(resolution) == "table"
        and resolution.scratch == true
    local main_is_scratch = buffer_is_scratch and util.same_path(path, main)
    project.source_kind = main_is_scratch and "scratch" or "file"
    project.scratch = main_is_scratch

    transfer_buffer(bufnr, key)
    project.bufs[bufnr] = true
    graph_sources.add(
        project,
        path,
        project_model.association_source_for(path, main, resolution)
    )
    graph_sources.add(project, main, "explicit")
    local compiler_state = compiler_service.get(project) or {}
    if
        compiler_state.process
        or compiler_state.watcher
        or compiler_state.stopping_compile
    then
        -- Preserve live handles while refreshing derived output state. Replacing
        -- the compiler table here would orphan a running compile/watch job.
        compiler_service.set(project, {
            output = compiler_state.output
                or project_model.output_path(project),
        })
    else
        compiler_service.set(project, {
            output = project_model.output_path(project),
        })
    end
    project_store.set_buffer(bufnr, key)
    record_resolution(project, bufnr, path, resolution)
    return project
end

--- Resolve root/main data for a buffer without mutating project registry state.
---@param bufnr integer Buffer to resolve.
---@param resolve_opts? table Resolution controls such as ignored previous project key.
---@return table candidate Attachment candidate with root, main, path, and resolution metadata.
function M.resolve_candidate(bufnr, resolve_opts)
    return project_resolver.resolve_candidate(bufnr, resolve_opts)
end

--- Commit a resolved attachment candidate into the project registry.
---@param candidate table Candidate returned by `resolve_candidate`.
---@return TypstProject state Attached project state.
function M.commit_attach(candidate)
    if type(candidate) ~= "table" then
        error("typst.nvim: project attach candidate is required")
    end

    return create_or_update(
        candidate.root,
        candidate.main,
        candidate.bufnr,
        candidate.path,
        candidate.resolution
    )
end

--- Resolve and attach a buffer to its Typst project.
---@param bufnr integer Buffer to resolve and attach.
---@param resolve_opts? table Resolution controls forwarded to `resolve_candidate`.
---@return TypstProject state Attached project state.
function M.resolve(bufnr, resolve_opts)
    return M.commit_attach(M.resolve_candidate(bufnr, resolve_opts))
end

--- Resolve a project from common option tables without duplicating fallback rules.
---@param opts? table|integer Options with `project`/`bufnr`, or a bufnr.
---@param resolve_opts? {create?: boolean}
---@return TypstProject|nil state Resolved project state, if available.
function M.resolve_opts(opts, resolve_opts)
    return context.resolve(opts, resolve_opts)
end

--- Return the project currently attached to a buffer.
---@param bufnr integer Buffer whose attached project should be returned.
---@return TypstProject|nil state Attached project state, if any.
function M.get(bufnr)
    bufnr = normalize_bufnr(bufnr)
    return project_store.project_for_buffer(bufnr)
end

--- Check whether a buffer's attached main file is no longer readable.
---@param state TypstProject? Project state attached to the buffer.
---@param bufnr? integer Buffer whose resolution should be checked.
---@return boolean stale True when the attached main path appears stale.
function M.main_stale(state, bufnr)
    if not state or not state.main then
        return false
    end

    bufnr = normalize_bufnr(bufnr)
    local resolution = state.resolutions and state.resolutions[bufnr]
    if resolution and resolution.scratch then
        return false
    end
    if
        resolution
        and resolution.allow_unreadable_explicit_main == true
        and resolution.main_source == "buffer variable vim.b.typst_main"
    then
        return false
    end

    local path = current_buffer_path(bufnr)
    if path and util.same_path(state.main, path) then
        return false
    end

    return not util.readable(state.main)
end

--- Remove a buffer from its attached project and prune empty state.
---@param bufnr integer Buffer to detach.
---@return TypstProject|nil state Project state the buffer belonged to before detach.
function M.detach(bufnr)
    bufnr = normalize_bufnr(bufnr)
    local key = project_store.key_for_buffer(bufnr)
    if not key then
        return nil
    end

    local state = project_store.get(key)
    require("typst.project.attachments").forget(bufnr, key)
    project_store.clear_buffer(bufnr)

    if state then
        state.bufs[bufnr] = nil
        diagnostics.clear_buffer(state, bufnr, { emit = false })
        state.resolutions[bufnr] = nil
        project_model.refresh_resolution_pending(state)
        log.add("info", "detached buffer", { bufnr = bufnr, main = state.main })
        rebuild_files(state)
        project_store.prune_if_empty(state, "buffer detached")
    end

    return state
end

--- Set a buffer-local explicit main file and re-resolve its project.
---@param bufnr integer Buffer receiving the explicit main.
---@param main string Main file path. Empty string uses the current buffer.
---@param opts? {persist?:boolean, force?:boolean} Persistence and validation controls. Main must be readable unless `force` is true.
---@return TypstProject state Project state after re-resolution.
function M.set_main(bufnr, main, opts)
    opts = opts or {}
    bufnr = normalize_bufnr(bufnr)
    local path = current_buffer_path(bufnr)
    if not path then
        error("typst.nvim: current buffer has no file name")
    end

    local root = root_discovery.detect(path, bufnr, config.unsafe_get())
    local target = type(main) == "string" and main ~= "" and main or path
    local resolved = util.resolve_path(target, root)
    if type(resolved) ~= "string" or resolved == "" then
        error(
            ("typst.nvim: could not resolve Typst main path %q"):format(
                tostring(target)
            )
        )
    end
    if opts.force ~= true and not util.readable(resolved) then
        error(
            ("typst.nvim: Typst main file is not readable: %s; use force=true or :TypstSetMain! to set it anyway"):format(
                resolved
            )
        )
    end

    local had_previous_buf_var = util.get_buf_var(bufnr, "typst_main") ~= nil
    local previous_buf_var = util.get_buf_var(bufnr, "typst_main")
    local persist_main = opts.persist
        and config.unsafe_get().project.persist_main
    local previous_persisted = persist_main and state_store.explicit_main(path)
        or nil

    local function restore_previous_main()
        if had_previous_buf_var then
            util.set_buf_var(bufnr, "typst_main", previous_buf_var)
        else
            util.del_buf_var(bufnr, "typst_main")
        end
        if persist_main then
            if previous_persisted then
                state_store.set_explicit_main(path, previous_persisted)
            else
                state_store.clear_explicit_main(path)
            end
        end
    end

    util.set_buf_var(bufnr, "typst_main", resolved)
    if persist_main then
        state_store.set_explicit_main(path, resolved)
    end
    log.add("info", "set buffer main", { buffer = path, main = resolved })
    local ok, state = xpcall(function()
        return M.resolve(bufnr, {
            allow_unreadable_explicit_main = opts.force == true,
        })
    end, debug.traceback)
    if not ok then
        restore_previous_main()
        error(state, 0)
    end
    return state
end

--- Clear a buffer-local explicit main file and re-resolve its project.
---@param bufnr integer Buffer whose explicit main should be cleared.
---@param opts? table Clear controls such as `clear_persisted`.
---@return TypstProject state Project state after re-resolution.
function M.clear_main(bufnr, opts)
    opts = opts or {}
    bufnr = normalize_bufnr(bufnr)
    local path = current_buffer_path(bufnr)
    if not path then
        error("typst.nvim: current buffer has no file name")
    end

    local previous_key = project_store.key_for_buffer(bufnr)
    local previous = previous_key and project_store.get(previous_key) or nil
    if previous_key then
        require("typst.project.attachments").forget(bufnr, previous_key)
    end
    if previous then
        previous.bufs[bufnr] = nil
        diagnostics.clear_buffer(previous, bufnr, { emit = false })
        previous.resolutions[bufnr] = nil
        project_model.refresh_resolution_pending(previous)
        project_store.clear_buffer(bufnr)
        rebuild_files(previous)
        project_store.prune_if_empty(previous, "buffer main cleared")
    end

    util.del_buf_var(bufnr, "typst_main")
    if opts.clear_persisted ~= false then
        state_store.clear_explicit_main(path)
    end
    log.add("info", "cleared buffer main", { buffer = path })
    return M.resolve(bufnr, { ignore_project_key = previous_key })
end

--- Update a project's dependency graph from compiler or scanner paths.
---@param project TypstProject Project state whose dependencies should be updated.
---@param paths string[]|table Dependency paths or keyed dependency map.
---@param opts? table Dependency update options.
---@return any result Dependency update result.
function M.update_dependencies(project, paths, opts)
    return dependencies.update(project, paths, opts)
end

--- Return public snapshots for all registered projects keyed by project key.
---@param opts? table Snapshot options.
---@return table<string, table> registry Public project snapshots keyed by project key.
function M.all(opts)
    local snapshots = {}
    for key, state in pairs(project_store.all()) do
        snapshots[key] = context.snapshot(state, opts)
    end
    return snapshots
end

--- Return a public snapshot for one project or buffer.
---@param state_or_bufnr TypstProject|integer Project state or buffer number.
---@param opts? table Snapshot options.
---@return table? snapshot Project snapshot, or nil when no project exists.
function M.snapshot(state_or_bufnr, opts)
    if type(state_or_bufnr) == "table" then
        return context.snapshot(state_or_bufnr, opts)
    end

    return context.snapshot(M.get(state_or_bufnr), opts)
end

--- Return public snapshots for all registered projects.
---@param opts? table Snapshot options.
---@return table[] snapshots Project snapshots.
function M.all_snapshots(opts)
    return context.list(project_store.all(), opts)
end

--- Prune a project if it no longer owns buffers or active resources.
---@param state TypstProject|string Project state or project key.
---@param reason? string Human-readable prune reason.
---@return boolean? pruned True when the project was removed.
function M.prune(state, reason)
    return project_store.prune(state, reason)
end

--- Check whether a project was removed from the registry.
---@param state TypstProject? Project state to inspect.
---@return boolean pruned True when the project registry has pruned this state.
function M.pruned(state)
    return type(state) == "table" and state._typst_project_pruned == true
end

--- Emit the delayed project-pruned lifecycle event after buffer-detach events.
---@param state TypstProject? Project state that may have been pruned.
---@param reason? string Reason override for the event payload.
---@return boolean emitted True when the event was emitted.
function M.emit_pruned(state, reason)
    return project_store.emit_project_pruned(state, reason)
end

--- Clear all project registry state.
function M.reset()
    project_store.reset()
end

return M
