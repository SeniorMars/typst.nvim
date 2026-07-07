local diagnostics = require("typst.diagnostics")

local M = {}

local function diagnostic_total(by_buffer)
    local count = 0
    for _, buffer_diagnostics in pairs(by_buffer or {}) do
        count = count + #buffer_diagnostics
    end
    return count
end

local function maybe_open_quickfix(state, by_buffer, opts)
    if not opts.open then
        return {}
    end

    local items = diagnostics.set_quickfix(state, by_buffer)
    if #items > 0 then
        pcall(vim.cmd, "copen")
    end
    return items
end

---Create a result publisher for command/provider diagnostic tools.
---@param spec {source:string,generation_field:string,state_generation_field?:string,stale_message:string,publish_failed_message:string,invalid_result_message:string,normalize_output?:fun(output:string, fields:table, opts:table, state:table):string,output_fields?:fun(result:table, provider_name:string, opts:table, state:table):table,by_buffer_fields?:fun(result:table, provider_name:string, opts:table, state:table):table}
---@return table helper
function M.new(spec)
    local helper = {}
    local generation_field = spec.generation_field
    local state_generation_field = spec.state_generation_field
        or generation_field

    local function generation_stale(state, opts)
        local generation = opts and opts[generation_field]
        return generation ~= nil
            and state
            and state[state_generation_field] ~= generation
    end

    function helper.stale_result(opts, fields)
        return vim.tbl_extend(
            "force",
            {
                ok = false,
                stale = true,
                reason = "stale_result",
                message = spec.stale_message,
            },
            fields or {},
            {
                generation = opts and opts[generation_field],
            }
        )
    end

    helper.diagnostic_total = diagnostic_total
    helper.maybe_open_quickfix = maybe_open_quickfix

    function helper.publish_output(state, output, opts, fields)
        opts = opts or {}
        fields = fields or {}
        if generation_stale(state, opts) then
            return helper.stale_result(opts, fields)
        end

        output = output or ""
        if type(spec.normalize_output) == "function" then
            output = spec.normalize_output(output, fields, opts, state)
        end

        local by_buffer, publish_err
        if output == "" then
            diagnostics.clear(state, { source = spec.source })
            by_buffer = {}
        else
            by_buffer, publish_err =
                diagnostics.publish(state, output, { source = spec.source })
            if not by_buffer then
                return vim.tbl_extend("force", {
                    ok = false,
                    reason = publish_err and publish_err.reason
                        or "diagnostics_publish_failed",
                    message = publish_err and publish_err.message
                        or spec.publish_failed_message,
                    error = publish_err,
                    diagnostics = 0,
                    buffers = 0,
                    by_buffer = {},
                    quickfix = {},
                }, fields)
            end
        end

        local items = maybe_open_quickfix(state, by_buffer, opts)
        local count = diagnostic_total(by_buffer)
        return vim.tbl_extend("force", {
            ok = true,
            diagnostics = count,
            buffers = vim.tbl_count(by_buffer),
            by_buffer = by_buffer,
            quickfix = items,
        }, fields)
    end

    function helper.publish_by_buffer(state, by_buffer, opts, fields)
        opts = opts or {}
        fields = fields or {}
        if generation_stale(state, opts) then
            return helper.stale_result(opts, fields)
        end

        local published, items = diagnostics.publish_by_buffer(
            state,
            by_buffer or {},
            { source = spec.source }
        )
        if opts.open and #items == 0 then
            items = diagnostics.set_quickfix(state, published)
        end
        if opts.open and #items > 0 then
            pcall(vim.cmd, "copen")
        end
        local count = diagnostic_total(published)
        return vim.tbl_extend("force", {
            ok = true,
            diagnostics = count,
            buffers = vim.tbl_count(published),
            by_buffer = published,
            quickfix = items,
            published = true,
        }, fields)
    end

    function helper.normalize_provider_result(
        state,
        result,
        opts,
        provider_name
    )
        opts = opts or {}
        if generation_stale(state, opts) then
            return helper.stale_result(opts, { provider = provider_name })
        end

        if type(result) == "string" then
            result = { output = result }
        end

        if type(result) ~= "table" then
            return {
                ok = false,
                reason = "invalid_result",
                provider = provider_name,
                message = spec.invalid_result_message,
            }
        end

        if result.output ~= nil or result.text ~= nil then
            local output_fields = type(spec.output_fields) == "function"
                    and spec.output_fields(result, provider_name, opts, state)
                or {
                    provider = result.provider or provider_name,
                    code = result.code,
                }
            return helper.publish_output(
                state,
                result.output or result.text,
                opts,
                output_fields
            )
        end

        result.provider = result.provider or provider_name
        if result.by_buffer and result.published ~= true then
            local by_buffer_fields = type(spec.by_buffer_fields) == "function"
                    and spec.by_buffer_fields(
                        result,
                        provider_name,
                        opts,
                        state
                    )
                or {
                    provider = result.provider,
                    code = result.code,
                }
            local published = helper.publish_by_buffer(
                state,
                result.by_buffer,
                opts,
                by_buffer_fields
            )
            result = vim.tbl_extend("force", result, {
                diagnostics = published.diagnostics,
                buffers = published.buffers,
                by_buffer = published.by_buffer,
                quickfix = published.quickfix,
                published = true,
            })
        end
        if result.diagnostics == nil and result.by_buffer then
            result.diagnostics = diagnostic_total(result.by_buffer)
        end
        if result.ok == nil then
            result.ok = true
        end
        return result
    end

    return helper
end

return M
