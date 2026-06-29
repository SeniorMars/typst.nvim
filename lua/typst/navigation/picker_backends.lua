local config = require("typst.config")
local backend_impls = require("typst.navigation.picker_backend_impls")
local helpers = require("typst.navigation.picker_backend_helpers")
local providers = require("typst.integrations.providers")

---@class TypstPickerOpenHandlers
---@field open_item? fun(item: table, opts: table)

---@class TypstPickerOpenResult
---@field ok boolean
---@field backend string
---@field reason? string
---@field errors? table
---@field items table[]

-- Picker backend selection for navigation commands.
--
-- Explicit providers fail directly. The "auto" provider probes common picker
-- integrations in preference order and returns all rejection reasons only after
-- every backend declines, which makes troubleshooting optional dependencies
-- easier without changing the fast path.
local M = {}
local backends = backend_impls.backends

local function configured_provider(opts)
    local picker_config = config.unsafe_get().picker or {}
    return opts.backend or opts.provider or picker_config.provider or "auto"
end

function M.open(items, opts, handlers)
    opts = opts or {}
    local provider = configured_provider(opts)

    if type(provider) == "function" or type(provider) == "table" then
        return helpers.call_custom(provider, items, opts)
    end

    local registered = providers.get("picker", provider)
    if registered then
        return helpers.call_custom(registered, items, opts)
    end

    if provider == "custom" then
        return helpers.call_custom(
            opts.custom or (config.unsafe_get().picker or {}).custom,
            items,
            opts
        )
    end

    if #items == 0 then
        return helpers.empty_result(provider, items)
    end

    if provider == "auto" then
        local errors = {}
        for _, name in ipairs({
            "telescope",
            "fzf_lua",
            "fzf_vim",
            "snacks",
            "ui_select",
        }) do
            local result = backends[name](items, opts, handlers)
            if result.ok then
                return result
            end
            errors[name] = result.reason
        end
        return {
            ok = false,
            backend = "auto",
            reason = "unavailable",
            errors = errors,
            items = items,
        }
    end

    local backend = backends[provider]
    if backend then
        return backend(items, opts, handlers)
    end

    return helpers.unavailable(provider, items, "unknown_provider")
end

return M
