local config = require("typst.config")
local context = require("typst.project.context")
local log = require("typst.core.log")
local dependencies = require("typst.project.dependencies")
local diagnostics = require("typst.diagnostics")
local graph_match = require("typst.project.graph_match")
local index_cache = require("typst.project.index_cache")
local graph_sources = require("typst.project.graph.sources")
local main_file = require("typst.project.main_file")
local project_model = require("typst.project.model")
local project_services = require("typst.project.services")
local compiler_service = require("typst.project.services.compiler")
local root_discovery = require("typst.project.root")
local state_store = require("typst.core.state")
local util = require("typst.core.util")

local M = {}

-- Project ownership for Typst buffers.
--
-- A project is keyed by both root and main file because a single directory can
-- contain multiple documents, and a single Neovim session can edit several of
-- them at once. Buffer membership is tracked separately so moving a buffer to a
-- new main can detach diagnostics and compiler state from the old project.
local registry = {}
local buffer_projects = {}

local project_key = project_model.project_key
local normalize_bufnr = project_model.normalize_bufnr
local current_buffer_path = project_model.current_buffer_path
local scratch_buffer_path = project_model.scratch_buffer_path
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
end

---@param state TypstProject? Project that may be pruned.
---@param reason string Prune reason.
---@return boolean pruned True when the project was removed.
local function prune_if_empty(state, reason)
    if
        not state
        or next(state.bufs or {}) ~= nil
        or project_services.has_active_resources(state)
    then
        return false
    end

    registry[state.key] = nil
    index_cache.reset(state)
    state._typst_project_pruned = true
    state._typst_project_pruned_reason = reason
    log.add("info", "removed empty project", {
        main = state.main,
        reason = reason,
    })
    return true
end

---@param state TypstProject? Project that may have been pruned.
---@param reason? string Event reason override.
---@return boolean emitted True when a prune event was emitted.
local function emit_project_pruned(state, reason)
    if
        not state
        or state._typst_project_pruned ~= true
        or state._typst_project_pruned_event_emitted == true
    then
        return false
    end

    state._typst_project_pruned_event_emitted = true
    require("typst.core.events").emit("TypstProjectPruned", state, {
        event_kind = "project_pruned",
        reason = reason or state._typst_project_pruned_reason,
        remaining_buffers = 0,
        project_pruned = true,
    })
    return true
end

local function transfer_buffer(bufnr, next_key)
    local previous_key = buffer_projects[bufnr]
    if previous_key == nil or previous_key == next_key then
        return
    end

    local previous = registry[previous_key]
    if previous then
        previous.bufs[bufnr] = nil
        diagnostics.clear_buffer(previous, bufnr, { emit = false })
        previous.resolutions[bufnr] = nil
        log.add("info", "moved buffer to another project", {
            bufnr = bufnr,
            from = previous.main,
            to = next_key,
        })
        rebuild_files(previous)
        prune_if_empty(previous, "buffer moved")
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
    local project = registry[key]

    if not project then
        project = project_model.new_project(root, main, key)
        registry[key] = project
        log.add("info", "created project", { root = root, main = main })
    end

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
    buffer_projects[bufnr] = key
    record_resolution(project, bufnr, path, resolution)
    return project
end

--- Resolve root/main data for a buffer without mutating project registry state.
---@param bufnr integer Buffer to resolve.
---@param resolve_opts? table Resolution controls such as ignored previous project key.
---@return table candidate Attachment candidate with root, main, path, and resolution metadata.
function M.resolve_candidate(bufnr, resolve_opts)
    bufnr = normalize_bufnr(bufnr)
    resolve_opts = resolve_opts or {}
    local path = current_buffer_path(bufnr)
    local scratch = false
    if not path then
        path = scratch_buffer_path(bufnr)
        scratch = true
    end

    local opts = config.unsafe_get()
    local root, root_source = root_discovery.detect(path, bufnr, opts)
    if scratch and root_source == "buffer directory" then
        root, root_source =
            util.normalize(vim.fn.getcwd()), "unnamed buffer cwd"
    end
    local main, main_source = main_file.buffer_main(bufnr, root)
    main, main_source =
        main_file.discard_unreadable(bufnr, path, main, main_source)

    -- Main-file resolution is ordered from explicit user intent to heuristics.
    -- Scratch buffers skip persisted and filesystem scans because they have no
    -- stable path to use as a persistence key or import target.
    if not scratch and not main then
        main, main_source = main_file.persisted(path, opts)
        main, main_source =
            main_file.discard_unreadable(bufnr, path, main, main_source)
        root, root_source = root_discovery.reconcile_for_main(
            root,
            root_source,
            path,
            main,
            main_source
        )
    end

    if not scratch and not main then
        main, main_source = main_file.directive(path, bufnr)
        main, main_source =
            main_file.discard_unreadable(bufnr, path, main, main_source)
        root, root_source = root_discovery.reconcile_for_main(
            root,
            root_source,
            path,
            main,
            main_source
        )
    end

    if not main then
        main, main_source = main_file.configured(path, bufnr, root, opts)
        main, main_source =
            main_file.discard_unreadable(bufnr, path, main, main_source)
    end

    if not scratch and not main then
        local project_root, project_root_source
        main, main_source, project_root, project_root_source =
            main_file.project_file(path)
        main, main_source =
            main_file.discard_unreadable(bufnr, path, main, main_source)
        if main and root_source == "buffer directory" then
            root, root_source = project_root, project_root_source
        end
    end

    if not scratch and not main then
        local existing, ambiguous, graph_source =
            graph_match.existing_project_for(
                registry,
                path,
                resolve_opts.ignore_project_key
            )
        if existing then
            return {
                bufnr = bufnr,
                path = path,
                root = existing.root,
                main = existing.main,
                previous_key = buffer_projects[bufnr],
                resolution = {
                    root_source = "existing project",
                    main_source = "existing project graph",
                    graph_source = graph_source or "unknown",
                },
            }
        elseif ambiguous then
            log.add(
                "info",
                "project graph attachment was ambiguous; continuing resolver fallbacks",
                { path = path }
            )
        end
    end

    if not scratch and not main then
        local scan_root, scan_root_source
        main, main_source, scan_root, scan_root_source =
            root_discovery.import_scan_main(path, root, root_source, opts)
        if main then
            root, root_source = scan_root, scan_root_source
        end
    end

    if scratch and not main then
        main, main_source = path, "unnamed buffer"
    elseif not main then
        main, main_source = main_file.heuristic(path, root)
    end

    return {
        bufnr = bufnr,
        path = path,
        root = root,
        main = main,
        previous_key = buffer_projects[bufnr],
        resolution = {
            root_source = root_source,
            main_source = main_source,
            scratch = scratch,
        },
    }
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
    local key = buffer_projects[bufnr]
    return key and registry[key] or nil
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
    local key = buffer_projects[bufnr]
    if not key then
        return nil
    end

    local state = registry[key]
    buffer_projects[bufnr] = nil

    if state then
        state.bufs[bufnr] = nil
        diagnostics.clear_buffer(state, bufnr, { emit = false })
        state.resolutions[bufnr] = nil
        log.add("info", "detached buffer", { bufnr = bufnr, main = state.main })
        rebuild_files(state)
        prune_if_empty(state, "buffer detached")
    end

    return state
end

--- Set a buffer-local explicit main file and re-resolve its project.
---@param bufnr integer Buffer receiving the explicit main.
---@param main string Main path or empty string to use the current buffer.
---@param opts? table Persistence and resolution options.
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
    util.set_buf_var(bufnr, "typst_main", resolved)
    if opts.persist and config.unsafe_get().project.persist_main then
        state_store.set_explicit_main(path, resolved)
    end
    log.add("info", "set buffer main", { buffer = path, main = resolved })
    return M.resolve(bufnr)
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

    local previous_key = buffer_projects[bufnr]
    local previous = previous_key and registry[previous_key] or nil
    if previous then
        previous.bufs[bufnr] = nil
        diagnostics.clear_buffer(previous, bufnr, { emit = false })
        previous.resolutions[bufnr] = nil
        buffer_projects[bufnr] = nil
        rebuild_files(previous)
        prune_if_empty(previous, "buffer main cleared")
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

--- Return the live project registry.
---@return table<string, TypstProject> registry Project registry keyed by project key.
function M.all()
    return registry
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
    return context.list(registry, opts)
end

--- Prune a project if it no longer owns buffers or active resources.
---@param state TypstProject|string Project state or project key.
---@param reason? string Human-readable prune reason.
---@return boolean? pruned True when the project was removed.
function M.prune(state, reason)
    if type(state) == "string" then
        state = registry[state]
    end

    local pruned = prune_if_empty(state, reason or "manual prune")
    if pruned then
        emit_project_pruned(state, reason or "manual prune")
    end
    return pruned
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
    return emit_project_pruned(state, reason)
end

--- Clear all project registry state.
function M.reset()
    registry = {}
    buffer_projects = {}
end

return M
