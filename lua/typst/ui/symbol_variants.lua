local metadata = require("typst.metadata")

local M = {}

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

local function unique_sorted(values)
    local seen = {}
    local result = {}
    for _, name in ipairs(values or {}) do
        if name and not seen[name] then
            seen[name] = true
            result[#result + 1] = name
        end
    end

    table.sort(result)
    return result
end

function M.lookup(query)
    query = trim(query)
    if not query then
        return nil, nil, false
    end

    local explicit = query:sub(1, 4) == "sym."
    local name = explicit and query:sub(5) or query
    local record = metadata.symbol(name)
    if record then
        name = record.name or record.canonical or name
    end
    return record, name, explicit
end

function M.list(query)
    local record, name = M.lookup(query)
    if not record then
        return {}
    end
    return unique_sorted(metadata.symbol_variants(name))
end

function M.action(ctx, opts)
    opts = opts or {}
    local record, name, explicit = M.lookup(ctx and ctx.query)
    if not record or #metadata.symbol_variants(name) == 0 then
        return nil
    end

    return {
        id = "symbol_insert_variant",
        title = ("Insert symbol variant for %s"):format(ctx.query),
        kind = "symbol",
        context = ctx,
        run = function(run_opts)
            run_opts = run_opts or {}
            local function apply_variant(variant)
                if not variant then
                    return nil
                end

                local replacement = explicit and ("sym." .. variant) or variant
                return opts.replace_range(opts.bufnr, ctx.range, replacement)
            end

            if run_opts.variant then
                return apply_variant(run_opts.variant)
            end

            if run_opts.open == false then
                return M.list(name)
            end

            vim.ui.select(M.list(name), {
                prompt = ("Typst symbol variants: %s"):format(name),
                format_item = function(variant)
                    local variant_record = metadata.symbol(variant)
                    local glyph = variant_record and variant_record.glyph
                        or record.glyph
                    return ("%s  %s"):format(variant, glyph or "")
                end,
            }, apply_variant)

            return M.list(name)
        end,
    }
end

return M
