local log = require("typst.core.log")
local provider_adapter = require("typst.integrations.provider_adapter")

local M = {}

function M.prompt_for(opts)
    return opts.prompt or "Typst project items"
end

function M.empty_result(provider, items)
    log.add("info", "picker opened with no items", { provider = provider })
    return {
        ok = false,
        backend = provider,
        reason = "empty",
        items = items,
    }
end

function M.unavailable(provider, items, reason)
    return {
        ok = false,
        backend = provider,
        reason = reason or "unavailable",
        items = items,
    }
end

function M.custom_result(provider, result, items)
    if result == nil then
        result = { ok = true }
    elseif type(result) ~= "table" then
        result = { ok = true, value = result }
    end
    result.backend = result.backend or provider
    result.items = result.items or items
    return result
end

function M.call_custom(provider, items, opts)
    if type(provider) == "table" then
        if
            type(provider.open) ~= "function"
            and type(provider.pick) ~= "function"
            and type(provider.items) ~= "function"
        then
            return M.unavailable("custom", items, "missing_custom_provider")
        end
    elseif type(provider) ~= "function" then
        return M.unavailable("custom", items, "missing_custom_provider")
    end

    local name = type(provider) == "table" and provider.name or "custom"
    return provider_adapter.invoke(
        provider,
        { "open", "pick", "items" },
        items,
        opts,
        {
            kind = "picker",
            provider_name = name,
            async = false,
            allow_nil_result = true,
            args = { items, opts },
            callback_position = 3,
            normalize = function(result)
                return M.custom_result(name or "custom", result, items)
            end,
        }
    )
end

function M.open_item(handlers, item, opts)
    if handlers and type(handlers.open_item) == "function" then
        return handlers.open_item(item, opts)
    end
end

function M.indexed_entries(items)
    local entries = {}
    local by_entry = {}
    for index_, item in ipairs(items) do
        local entry = ("%4d  %s"):format(index_, item.label)
        entries[#entries + 1] = entry
        by_entry[entry] = item
    end
    return entries, by_entry
end

return M
