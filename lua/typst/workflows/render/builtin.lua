local async = require("typst.core.async")
local events = require("typst.core.events")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local output_ownership = require("typst.resources.outputs")
local providers = require("typst.integrations.providers")
local render_cleanup = require("typst.workflows.render.cleanup")
local render_display = require("typst.workflows.render.display")
local generation_state = require("typst.workflows.render.generation")

local M = {}

local notify_user = require("typst.core.notify").user

local function callback_result(callback, result, project)
    if callback then
        callback(result, providers.project_context(project))
    end
end

function M.attach(ctx)
    local project = ctx.project
    local kind = ctx.kind
    local opts = ctx.opts or {}
    local path = ctx.path
    local source_path = ctx.source_path
    local result = {
        ok = true,
        pending = true,
        key = ctx.key,
        kind = kind,
        path = path,
        source_path = source_path,
        format = opts.format,
        command = ctx.command,
        cached = false,
    }
    if ctx.page then
        result.page = ctx.page
    end

    operation.attach(
        result,
        ctx.operation_kind or ("render-" .. kind),
        ctx.command,
        {
            cwd = project.root,
            text = true,
            detach = false,
            stdin = ctx.stdin and ctx.source or nil,
        },
        {
            owner = "project",
            project_key = project.key,
            cleanup = function()
                output_ownership.release(ctx.lease)
            end,
            on_finish = function(exit)
                if async.cancelled(result) then
                    render_cleanup.unremembered(result, project, "cancelled")
                    return
                end

                local stale = generation_state.is_stale(
                    project,
                    kind,
                    ctx.generation,
                    ctx.token
                ) and generation_state.stale_result(
                    kind,
                    ctx.generation,
                    ctx.token
                ) or nil
                if stale then
                    generation_state.apply_stale_result(result, stale)
                    callback_result(ctx.callback, result, project)
                    render_cleanup.unremembered(result, project, "stale_result")
                    return
                end

                result.pending = false
                result.code = exit.code
                result.stdout = exit.stdout
                result.stderr = exit.stderr
                result.ok = exit.code == 0 and vim.fn.filereadable(path) == 1
                if result.ok then
                    ctx.cache_api.remember(result, opts)
                    events.emit("TypstRenderCreated", project, {
                        kind = kind,
                        path = path,
                        source = source_path,
                        format = opts.format,
                        page = ctx.page,
                    })
                    render_display.display(result, opts, ctx.notify)
                    if ctx.cleanup_generated_source then
                        render_cleanup.generated_source(
                            project,
                            source_path,
                            "finished"
                        )
                    end
                else
                    if ctx.log_failure then
                        log.add("error", "render failed", {
                            kind = kind,
                            path = path,
                            stderr = exit.stderr,
                            stdout = exit.stdout,
                        })
                    end
                    if ctx.cleanup_generated_source then
                        render_cleanup.generated_source(
                            project,
                            source_path,
                            "failed"
                        )
                    end
                    notify_user(
                        ctx.notify,
                        ctx.failure_message or "Typst rendered preview failed",
                        vim.log.levels.ERROR
                    )
                end
                callback_result(ctx.callback, result, project)
            end,
        }
    )

    return result
end

return M
