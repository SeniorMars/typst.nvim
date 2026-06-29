local path_leases = require("typst.core.path_leases")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local util = require("typst.core.util")

local M = {}

local function provider_for(opts, render_config)
    return providers.resolve(
        "render",
        opts.provider or render_config(opts).provider
    )
end

function M.call(project, kind, opts, context)
    -- Custom render providers get the same lease and stale-result treatment as
    -- built-in Typst renders; late provider callbacks must not replace a newer
    -- preview result.
    local provider = provider_for(opts, context.render_config)
    if provider == nil or provider == "typst" then
        return nil
    end

    local generation = context.generation
    local lease = nil
    local lease_path = opts.output_path or opts.path
    if type(lease_path) == "string" and lease_path ~= "" then
        local parent_ok, parent_err = util.ensure_parent(lease_path)
        if not parent_ok then
            context.rollback_generation(project, kind, generation)
            return {
                ok = false,
                pending = false,
                reason = "parent_create_failed",
                message = tostring(parent_err),
                kind = kind,
                path = lease_path,
                generation = generation,
            }
        end

        local lease_err
        lease, lease_err = path_leases.acquire(lease_path, {
            kind = "render-provider-" .. kind,
            project_key = project.key,
            main = project.main,
            generation = generation,
        })
        if not lease then
            ---@cast lease_err table
            context.rollback_generation(project, kind, generation)
            return {
                ok = false,
                pending = false,
                reason = lease_err.reason,
                message = lease_err.message,
                active_output = lease_err.active_output or lease_path,
                kind = kind,
                path = lease_path,
                generation = generation,
            }
        end
    end

    local released = false
    local function release_lease()
        if released then
            return
        end
        released = true
        if lease then
            path_leases.release(lease)
        end
    end

    local provider_project = providers.project_context(project)
    local provider_opts = vim.tbl_extend("force", opts, { kind = kind })
    local provider_callback = context.callback
        and function(result)
            local delivered = result
            if context.is_stale(project, kind, generation) then
                delivered = context.stale_result(kind, generation)
            elseif type(delivered) == "table" and delivered.pending ~= true then
                delivered = context.finalize_result(delivered, opts)
            end
            context.callback(delivered, provider_project)
        end

    local returned = provider_adapter.invoke(
        provider,
        { "render", kind, "run" },
        provider_project,
        provider_opts,
        {
            kind = "render",
            provider_name = type(provider) == "table" and provider.name
                or "callback",
            args = { provider_project, provider_opts },
            on_result = provider_callback,
            timeout_ms = opts.timeout_ms
                or context.render_config(opts).timeout_ms,
            normalize = function(result, provider_name)
                if type(result) == "table" then
                    result.provider = result.provider or provider_name
                    result.kind = result.kind or kind
                    result.generation = generation
                end
                if type(result) ~= "table" or result.pending ~= true then
                    release_lease()
                end
                return result
            end,
            invalid_result_message = "Render provider returned no result",
        }
    )
    if type(returned) ~= "table" or returned.pending ~= true then
        release_lease()
    end
    return returned
end

return M
