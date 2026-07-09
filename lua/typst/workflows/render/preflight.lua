local output_ownership = require("typst.resources.outputs")
local render_generation = require("typst.workflows.render.generation")
local planner = require("typst.workflows.render.planner")

local M = {}

local function path_failure(kind, path_error)
    return vim.tbl_extend("force", path_error or {
        ok = false,
        reason = "output_path_invalid",
        message = "Invalid Typst render output path",
    }, {
        pending = false,
        kind = kind,
    })
end

local function lease_failure(path, lease_err)
    lease_err = lease_err or {
        reason = "lease_failed",
        message = "Failed to acquire render output lease",
    }
    return {
        ok = false,
        pending = false,
        reason = lease_err.reason,
        message = lease_err.message,
        active_output = lease_err.active_output or path,
        path = path,
    }
end

local function parent_failure(path, err)
    return {
        ok = false,
        pending = false,
        reason = "parent_create_failed",
        message = tostring(err),
        path = path,
    }
end

local function rollback_failure(project, kind, generation, result, meta)
    render_generation.rollback(project, kind, generation)
    return nil, result, meta or {}
end

local function acquire_lease(project, kind, path, generation)
    local lease, lease_err = output_ownership.acquire(path, {
        kind = "render-" .. kind,
        project_key = project.key,
        main = project.main,
        generation = generation,
    })
    if not lease then
        return nil, lease_failure(path, lease_err)
    end
    return lease
end

local function ensure_parent(project, kind, generation, lease, path)
    local parent_ok, parent_err = output_ownership.ensure_parent(path)
    if parent_ok then
        return true
    end

    output_ownership.release(lease)
    return rollback_failure(
        project,
        kind,
        generation,
        parent_failure(path, parent_err)
    )
end

function M.path_failure(kind, err)
    return path_failure(kind, err)
end

function M.plan_source(project, kind, opts, generation)
    local key, path, source_path, stdin_source, path_error =
        planner.output_path(project, kind, opts)
    if path_error or not path then
        return rollback_failure(
            project,
            kind,
            generation,
            path_failure(kind, path_error),
            { callback = true }
        )
    end
    opts.output_path = opts.output_path or path
    opts.source_path = opts.source_path or source_path
    opts.stdin_source = opts.stdin_source or stdin_source

    return {
        key = key,
        path = path,
        source_path = source_path,
        stdin_source = stdin_source,
    }
end

function M.prepare_source(project, kind, source, opts, generation, plan)
    local key = plan.key
    local path = plan.path
    local source_path = plan.source_path
    local stdin_source = plan.stdin_source

    -- Reserve output before writing the temporary source so compile/export/watch
    -- jobs cannot target the same preview file while this render is pending.
    local lease, lease_err = acquire_lease(project, kind, path, generation)
    if not lease then
        return rollback_failure(project, kind, generation, lease_err)
    end

    local ok, result, meta =
        ensure_parent(project, kind, generation, lease, path)
    if not ok then
        return nil, result, meta
    end

    local source_mode, source_reason, source_message =
        planner.generated_source_mode(project, source_path, stdin_source)
    if not source_mode then
        output_ownership.release(lease)
        return rollback_failure(project, kind, generation, {
            ok = false,
            reason = source_reason,
            message = source_message,
            path = path,
            source_path = source_path,
        })
    end

    if source_mode == "file" then
        local write_ok, write_err = planner.write_source(source_path, source)
        if not write_ok then
            output_ownership.release(lease)
            return rollback_failure(project, kind, generation, {
                ok = false,
                reason = "write_failed",
                message = tostring(write_err),
                path = path,
            })
        end
    end

    opts.stdin_source = source_mode == "stdin"
    opts.compile_root =
        planner.compile_root_for_source(project, source_path, source_mode)

    return {
        key = key,
        path = path,
        source_path = source_path,
        lease = lease,
        command = planner.command_for(project, source_path, path, opts),
        stdin = opts.stdin_source,
    }
end

function M.plan_page(project, opts, generation)
    local key, path, _, _, path_error = planner.output_path(
        project,
        "page",
        opts
    )
    if path_error or not path then
        return rollback_failure(
            project,
            "page",
            generation,
            path_failure("page", path_error),
            { callback = true }
        )
    end
    opts.output_path = opts.output_path or path

    return {
        key = key,
        path = path,
        source_path = project.main,
    }
end

function M.prepare_page(project, opts, generation, plan)
    local key = plan.key
    local path = plan.path

    local lease, lease_err = acquire_lease(project, "page", path, generation)
    if not lease then
        return rollback_failure(project, "page", generation, lease_err, {
            callback = true,
        })
    end

    local ok, result, meta =
        ensure_parent(project, "page", generation, lease, path)
    if not ok then
        if meta then
            meta.callback = true
        end
        return nil, result, meta
    end

    return {
        key = key,
        path = path,
        source_path = project.main,
        lease = lease,
        command = planner.command_for(project, project.main, path, opts),
    }
end

return M
