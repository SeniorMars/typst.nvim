local M = {}

local services = require("typst.project.services")
local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local scalar_types = {
    boolean = true,
    number = true,
    string = true,
}

local public_fields = {
    "key",
    "instance_id",
    "root",
    "main",
    "root_source",
    "main_source",
    "main_confidence",
    "main_confidence_source",
    "resolution_pending",
    "source_kind",
    "scratch",
}

local public_tables = {
    "bufs",
    "resolutions",
    "last_resolution",
}

local function can_create_project_from_buffer(bufnr, opts)
    opts = opts or {}
    if opts.allow_non_typst_create == true then
        return true
    end
    if
        type(bufnr) ~= "number"
        or bufnr <= 0
        or not vim.api.nvim_buf_is_valid(bufnr)
    then
        return false
    end
    if vim.bo[bufnr].filetype == "typst" then
        return true
    end

    local name = vim.api.nvim_buf_get_name(bufnr)
    return type(name) == "string" and name:match("%.typ$") ~= nil
end

local function copyable_key(key)
    return key == nil or scalar_types[type(key)] == true
end

local function copy_value(value, depth, seen)
    local kind = type(value)
    if scalar_types[kind] or value == nil then
        return value
    end
    if kind ~= "table" or depth <= 0 then
        return nil
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local out = {}
    seen[value] = out
    for key, child in pairs(value) do
        if copyable_key(key) then
            local copied = copy_value(child, depth - 1, seen)
            if copied ~= nil then
                out[key] = copied
            end
        end
    end
    return out
end

local function copy_field(out, project, name, depth)
    local value = project and project[name]
    local copied = copy_value(value, depth or 4)
    if copied ~= nil then
        out[name] = copied
    end
end

--- Resolve a project from common option tables.
---
--- This helper intentionally mirrors the local `project_for(opts)` pattern used
--- across project-scoped workflows: explicit project objects win, attached
--- buffer state is reused, and resolution is attempted only when requested.
---@param opts? table|integer Options with `project`/`bufnr`, or a bufnr.
---@param resolve_opts? {create?: boolean, settle_pending?: boolean}
---@return table|nil project Resolved project state, if available.
function M.resolve(opts, resolve_opts)
    resolve_opts = resolve_opts or {}
    if type(opts) ~= "table" then
        opts = { bufnr = opts }
    end

    if type(opts.project) == "table" then
        if opts.project.mutable == false then
            return M.live(opts.project)
        end
        return opts.project
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local registry = require("typst.project")
    local state = registry.get(bufnr)
    if state and state.resolution_pending and resolve_opts.settle_pending then
        local ok, resolved =
            pcall(require("typst.project.lifecycle").get_project, bufnr)
        return ok and resolved or state
    end
    if state or resolve_opts.create == false then
        return state
    end

    if not can_create_project_from_buffer(bufnr, resolve_opts) then
        return nil
    end

    local ok, resolved = pcall(registry.resolve, bufnr)
    return ok and resolved or nil
end

--- Resolve a public project snapshot back to its live project state.
---@param project table? Public snapshot or live project table.
---@return TypstProject|nil project Live project state when the input is a public snapshot.
function M.live(project)
    if
        type(project) ~= "table"
        or project.mutable ~= false
        or type(project.key) ~= "string"
    then
        return nil
    end
    local live = require("typst.project.store").get(project.key)
    if not live or live.instance_id ~= project.instance_id then
        return nil
    end
    return live
end

function M.snapshot(project, opts)
    opts = opts or {}
    if type(project) ~= "table" then
        return nil
    end

    local out = {}
    for _, field in ipairs(public_fields) do
        copy_field(out, project, field, 1)
    end
    for _, field in ipairs(public_tables) do
        copy_field(out, project, field, opts.depth or 5)
    end

    local service_state = services.ensure(project) or {}
    local compiler = service_state.compiler or {}
    local preview = service_state.preview or {}
    local artifacts = service_state.artifacts or {}
    local diagnostics = service_state.diagnostics or {}
    local graph = service_state.graph or {}
    local viewer = service_state.viewer or {}
    out.output = compiler.output
    out.status = compiler.status
    out.last_profile = compiler.last_profile
    out.last_cwd = compiler.last_cwd
    out.active_compile_deps_path = compiler.active_compile_deps_path
    out.preview_active = preview.active == true
    out.compile_generation = compiler.generation
    out.watch_generation = compiler.watch_generation
    out.watch_cycle_generation = compiler.watch_cycle_generation
    out.last_command = copy_value(compiler.last_command, opts.depth or 5)
    out.last_result = copy_value(compiler.last_result, opts.depth or 5)
    out.diagnostic_buffers = copy_value(diagnostics.buffers, opts.depth or 5)
    out.last_artifact = copy_value(artifacts.last, opts.depth or 5)
    out.artifacts = copy_value(artifacts.items, opts.depth or 5)
    out.files = copy_value(graph.files, opts.depth or 5)
    out.file_sources = copy_value(graph.file_sources, opts.depth or 5)
    out.dependencies = copy_value(graph.dependencies, opts.depth or 5)
    out.dependency_sources =
        copy_value(graph.dependency_sources, opts.depth or 5)
    out.last_viewer_provider = viewer.provider
    out.last_viewer_backend = viewer.backend
    out.last_viewer_command = copy_value(viewer.command, opts.depth or 5)
    out.last_viewer_cwd = viewer.cwd

    local project_index = service_state.index
    if type(project_index) == "table" then
        out.index = {
            generation = project_index.generation,
            provider_generation = project_index.provider_generation,
            dependency_generation = project_index.dependency_generation,
            file_generation = project_index.file_generation,
            buffer_generation = project_index.buffer_generation,
            stats = copy_value(project_index.stats, opts.depth or 5),
        }
    end

    local service_snapshot = services.snapshot(project) or {}
    out.invalidation = service_snapshot.invalidation

    out.services = service_snapshot

    if opts.runtime then
        out.process = compiler.process
        out.watcher = compiler.watcher
        out.stopping_compile = compiler.stopping_compile
    end

    out.mutable = false
    return out
end

function M.list(projects, opts)
    local out = {}
    for key, project in pairs(projects or {}) do
        out[key] = M.snapshot(project, opts)
    end
    return out
end

return M
