local resource_manager = require("typst.runtime.resource_manager")

local M = {}

function M.start(project, kind)
    -- Generations are per render kind: a slow equation preview must not
    -- invalidate an unrelated page render, but a newer equation request wins.
    project.render_generations = project.render_generations or {}
    project.render_generations[kind] = (project.render_generations[kind] or 0)
        + 1
    return project.render_generations[kind]
end

function M.rollback(project, kind, generation)
    if
        generation
        and project.render_generations
        and project.render_generations[kind] == generation
    then
        project.render_generations[kind] = generation - 1
    end
end

function M.token(project, kind)
    return resource_manager.token(project, "render:" .. kind)
end

function M.token_stale_result(token, kind, generation)
    if not token then
        return nil
    end
    local valid, reason = resource_manager.valid_token(token)
    if valid then
        return nil
    end
    return {
        ok = false,
        pending = false,
        stale = true,
        reason = reason or "stale_result",
        kind = kind,
        generation = generation,
        message = reason == "reset"
                and "A render result was ignored after typst.nvim reset"
            or "A render result was ignored after the project changed",
    }
end

function M.generation_stale(project, kind, generation)
    return generation ~= nil
        and project.render_generations
        and project.render_generations[kind] ~= generation
end

function M.is_stale(project, kind, generation, token)
    return M.token_stale_result(token, kind, generation) ~= nil
        or M.generation_stale(project, kind, generation)
end

function M.stale_result(kind, generation, token)
    local token_result = M.token_stale_result(token, kind, generation)
    if token_result then
        return token_result
    end
    return {
        ok = false,
        stale = true,
        reason = "stale_result",
        kind = kind,
        generation = generation,
        message = "A newer render request finished first",
    }
end

function M.apply_stale_result(target, stale)
    for key, value in pairs(stale or {}) do
        target[key] = value
    end
    target.pending = false
    return target
end

return M
