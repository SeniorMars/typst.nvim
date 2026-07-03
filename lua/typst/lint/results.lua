local diagnostics = require("typst.diagnostics")

local M = {}

local function generation_stale(state, opts)
    local generation = opts and opts.lint_generation
    return generation ~= nil and state and state.lint_generation ~= generation
end

function M.stale_result(opts, fields)
    return vim.tbl_extend(
        "force",
        {
            ok = false,
            stale = true,
            reason = "stale_result",
            message = "A newer lint request finished first",
        },
        fields or {},
        {
            generation = opts and opts.lint_generation,
        }
    )
end

function M.diagnostic_total(by_buffer)
    local count = 0
    for _, buffer_diagnostics in pairs(by_buffer or {}) do
        count = count + #buffer_diagnostics
    end
    return count
end

function M.maybe_open_quickfix(state, by_buffer, opts)
    if not opts.open then
        return {}
    end

    local items = diagnostics.set_quickfix(state, by_buffer)
    if #items > 0 then
        vim.cmd("copen")
    end
    return items
end

function M.publish_output(state, output, opts, fields)
    opts = opts or {}
    if generation_stale(state, opts) then
        -- Lint providers can finish out of order. A stale result is reported to
        -- its caller but must not clear or replace diagnostics from a newer run.
        return M.stale_result(opts, fields)
    end

    output = output or ""
    local by_buffer, publish_err
    if output == "" then
        diagnostics.clear(state, { source = "lint" })
        by_buffer = {}
    else
        by_buffer, publish_err =
            diagnostics.publish(state, output, { source = "lint" })
        if not by_buffer then
            return vim.tbl_extend("force", {
                ok = false,
                reason = publish_err and publish_err.reason
                    or "diagnostics_publish_failed",
                message = publish_err and publish_err.message
                    or "Typst lint diagnostics could not be published",
                error = publish_err,
                diagnostics = 0,
                buffers = 0,
                by_buffer = {},
                quickfix = {},
            }, fields or {})
        end
    end

    local items = M.maybe_open_quickfix(state, by_buffer, opts)
    local count = M.diagnostic_total(by_buffer)

    return vim.tbl_extend("force", {
        ok = true,
        diagnostics = count,
        buffers = vim.tbl_count(by_buffer),
        by_buffer = by_buffer,
        quickfix = items,
    }, fields or {})
end

function M.publish_by_buffer(state, by_buffer, opts, fields)
    if generation_stale(state, opts) then
        return M.stale_result(opts, fields)
    end

    local published, items = diagnostics.publish_by_buffer(
        state,
        by_buffer or {},
        { source = "lint" }
    )
    if opts.open and #items == 0 then
        items = diagnostics.set_quickfix(state, published)
    end
    if opts.open and #items > 0 then
        vim.cmd("copen")
    end
    local count = M.diagnostic_total(published)

    return vim.tbl_extend("force", {
        ok = true,
        diagnostics = count,
        buffers = vim.tbl_count(published),
        by_buffer = published,
        quickfix = items,
        published = true,
    }, fields or {})
end

function M.normalize_provider_result(state, result, opts, provider_name)
    if generation_stale(state, opts) then
        return M.stale_result(opts, { provider = provider_name })
    end

    if type(result) == "string" then
        result = { output = result }
    end

    if type(result) ~= "table" then
        return {
            ok = false,
            reason = "invalid_result",
            provider = provider_name,
            message = "Lint provider returned no result",
        }
    end

    if result.output ~= nil or result.text ~= nil then
        return M.publish_output(state, result.output or result.text, opts, {
            provider = result.provider or provider_name,
            code = result.code,
        })
    end

    result.provider = result.provider or provider_name
    if result.by_buffer and result.published ~= true then
        local published = M.publish_by_buffer(state, result.by_buffer, opts, {
            provider = result.provider,
            code = result.code,
        })
        result = vim.tbl_extend("force", result, {
            diagnostics = published.diagnostics,
            buffers = published.buffers,
            by_buffer = published.by_buffer,
            quickfix = published.quickfix,
            published = true,
        })
    end
    if result.diagnostics == nil and result.by_buffer then
        result.diagnostics = M.diagnostic_total(result.by_buffer)
    end
    if result.ok == nil then
        result.ok = true
    end
    return result
end

return M
