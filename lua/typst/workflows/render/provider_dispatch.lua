local generation_state = require("typst.workflows.render.generation")
local planner = require("typst.workflows.render.planner")
local render_display = require("typst.workflows.render.display")
local render_provider = require("typst.workflows.render.provider")

local M = {}

local notify_user = require("typst.core.notify").user

function M.finalize_result(result, opts, notify)
    if type(result) ~= "table" then
        return result
    end
    if result.pending == true then
        return result
    end
    if result.ok == false then
        notify_user(
            notify,
            result.message or "Typst render provider failed",
            vim.log.levels.ERROR
        )
        return result
    end
    return render_display.display(result, opts, notify)
end

function M.call(project, kind, opts, callback, notify, generation, token)
    return render_provider.call(project, kind, opts, {
        callback = callback,
        finalize_result = function(result, provider_opts)
            return M.finalize_result(result, provider_opts, notify)
        end,
        generation = generation,
        is_stale = function(stale_project, stale_kind, stale_generation)
            return generation_state.is_stale(
                stale_project,
                stale_kind,
                stale_generation,
                token
            )
        end,
        render_config = planner.render_config,
        rollback_generation = generation_state.rollback,
        stale_result = function(stale_kind, stale_generation)
            return generation_state.stale_result(
                stale_kind,
                stale_generation,
                token
            )
        end,
    })
end

return M
