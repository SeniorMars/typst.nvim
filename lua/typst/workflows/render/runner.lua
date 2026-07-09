local render_builtin = require("typst.workflows.render.builtin")
local render_cleanup = require("typst.workflows.render.cleanup")
local render_generation = require("typst.workflows.render.generation")
local planner = require("typst.workflows.render.planner")
local render_preflight = require("typst.workflows.render.preflight")
local providers = require("typst.integrations.providers")
local render_display = require("typst.workflows.render.display")
local render_provider_dispatch =
    require("typst.workflows.render.provider_dispatch")

local M = {}

function M.cleanup_generated_source(project, source_path, reason)
    return render_cleanup.generated_source(project, source_path, reason)
end

local function callback_result(callback, result, project)
    if callback then
        callback(result, providers.project_context(project))
    end
end

local function cache_api_or_empty(cache_api)
    cache_api = cache_api or {}
    return {
        cached_result = cache_api.cached_result or function(...)
            return nil
        end,
        remember = cache_api.remember or function(...) end,
    }
end

function M.source(project, kind, source, opts, callback, notify, cache_api)
    opts = opts or {}
    opts.source = source
    opts.format = opts.format or planner.render_config(opts).output_format
        or "svg"
    cache_api = cache_api_or_empty(cache_api)

    local generation = render_generation.start(project, kind)
    local manager_token = render_generation.token(project, kind)
    local plan, failure, failure_meta =
        render_preflight.plan_source(project, kind, opts, generation)
    if not plan then
        if failure_meta and failure_meta.callback then
            callback_result(callback, failure, project)
        end
        return failure
    end

    local provider_result = render_provider_dispatch.call(
        project,
        kind,
        opts,
        callback,
        notify,
        generation,
        manager_token
    )
    if provider_result ~= nil then
        if type(provider_result) == "table" then
            provider_result.kind = provider_result.kind or kind
            return render_provider_dispatch.finalize_result(
                provider_result,
                opts,
                notify
            )
        end
        return provider_result
    end

    local hit = cache_api.cached_result(project, kind, opts)
    if hit then
        return render_display.display(hit, opts, notify)
    end

    local prepared, failure, failure_meta =
        render_preflight.prepare_source(
            project,
            kind,
            source,
            opts,
            generation,
            plan
        )
    if not prepared then
        if failure_meta and failure_meta.callback then
            callback_result(callback, failure, project)
        end
        return failure
    end

    return render_builtin.attach({
        project = project,
        kind = kind,
        opts = opts,
        key = prepared.key,
        path = prepared.path,
        source_path = prepared.source_path,
        source = source,
        command = prepared.command,
        lease = prepared.lease,
        generation = generation,
        token = manager_token,
        callback = callback,
        notify = notify,
        cache_api = cache_api,
        stdin = prepared.stdin,
        operation_kind = ("render-%s"):format(kind),
        cleanup_generated_source = true,
        log_failure = true,
        failure_message = "Typst rendered preview failed",
    })
end

function M.page(project, opts, callback, notify, cache_api)
    opts = opts or {}
    opts.format = opts.format or planner.render_config(opts).output_format
        or "svg"
    opts.source = project.main
    opts.page = opts.page or 1
    cache_api = cache_api_or_empty(cache_api)

    local generation = render_generation.start(project, "page")
    local manager_token = render_generation.token(project, "page")
    local function finish_failure(result)
        callback_result(callback, result, project)
        return result
    end
    local plan, failure, failure_meta =
        render_preflight.plan_page(project, opts, generation)
    if not plan then
        if failure_meta and failure_meta.callback then
            return finish_failure(failure)
        end
        return failure
    end

    local provider_result = render_provider_dispatch.call(
        project,
        "page",
        opts,
        callback,
        notify,
        generation,
        manager_token
    )
    if provider_result ~= nil then
        if type(provider_result) == "table" then
            provider_result.kind = provider_result.kind or "page"
            return render_provider_dispatch.finalize_result(
                provider_result,
                opts,
                notify
            )
        end
        return provider_result
    end

    local hit = cache_api.cached_result(project, "page", opts)
    if hit then
        hit.page = opts.page
        return render_display.display(hit, opts, notify)
    end

    local prepared, failure, failure_meta =
        render_preflight.prepare_page(project, opts, generation, plan)
    if not prepared then
        if failure_meta and failure_meta.callback then
            return finish_failure(failure)
        end
        return failure
    end

    return render_builtin.attach({
        project = project,
        kind = "page",
        opts = opts,
        key = prepared.key,
        path = prepared.path,
        source_path = prepared.source_path,
        command = prepared.command,
        lease = prepared.lease,
        generation = generation,
        token = manager_token,
        callback = callback,
        notify = notify,
        cache_api = cache_api,
        page = opts.page,
        operation_kind = "render-page",
        failure_message = "Typst page preview failed",
    })
end

return M
