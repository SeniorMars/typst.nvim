local config = require("typst.config")
local log = require("typst.core.log")
local preview_service = require("typst.project.services.preview")
local source_map_service = require("typst.preview.source_maps")
local runtime = require("typst.preview.backends.delegated_runtime")

local M = {}

local function delegate_to_typst_preview(preview)
    return preview.provider == "typst-preview.nvim"
end

local function provider_label(provider)
    if type(provider) == "string" then
        return provider
    end
    if type(provider) == "function" then
        return "callback"
    end
    if type(provider) == "table" then
        return provider.name or "table"
    end
    return nil
end

--- Resolve the active preview backend label.
---@param project? table Project state whose active preview state may be used.
---@return string backend Backend label.
function M.backend(project)
    local preview = config.unsafe_get().preview
    if type(preview.open) == "function" then
        return "callback"
    end
    local preview_state = preview_service.get(project) or {}
    if project and preview_state.active and preview_state.active_backend then
        return preview_state.active_backend
    end
    if
        delegate_to_typst_preview(preview)
        and runtime.command_available("TypstPreview")
    then
        return "typst-preview.nvim"
    end
    if preview.provider == nil or preview.provider == "native" then
        local native = preview.native or "viewer"
        if native == "browser" or native == "auto" then
            return "native-browser"
        end
        return "viewer"
    end
    if preview.fallback == "view" then
        return "viewer"
    end
    return "none"
end

--- Return base preview capabilities and backend label.
---@param project? table Project state whose active preview state may be used.
---@return table capabilities Capability flags.
---@return string backend Backend label.
function M.base(project)
    local preview = config.unsafe_get().preview
    local source_map_capabilities = source_map_service.capabilities(project)
    local configured_forward = type(preview.forward) == "function"
    local configured_inverse = type(preview.inverse) == "function"
    local configured_source_map_forward = source_map_capabilities.forward
            == true
        and type((preview.source_maps or {}).forward) == "function"
    local configured_source_map_inverse = source_map_capabilities.inverse
            == true
        and type((preview.source_maps or {}).inverse) == "function"
    local capabilities = vim.tbl_extend("force", {
        forward = false,
        inverse = false,
        source_maps = false,
        browser_click = false,
    }, preview.capabilities or {})
    for capability, enabled in pairs(source_map_capabilities) do
        if type(capability) == "string" and enabled == true then
            capabilities[capability] = true
        end
    end
    local backend = M.backend(project)
    local source_map_provider = source_map_capabilities.provider
        or provider_label((preview.source_maps or {}).provider)
        or "source-maps"
    local source_sync_provider = (
        capabilities.source_maps == true
        or capabilities.inverse == true
        or capabilities.forward == true
        or capabilities.browser_click == true
    )
            and "declared"
        or "none"

    if configured_forward then
        capabilities.forward = true
        source_sync_provider = "callback"
    end
    if configured_inverse then
        capabilities.inverse = true
        source_sync_provider = "callback"
    end
    if configured_source_map_forward then
        capabilities.forward = true
        source_sync_provider = source_map_provider
    end
    if configured_source_map_inverse then
        capabilities.inverse = true
        source_sync_provider = source_map_provider
    end
    if
        (
            source_map_capabilities.source_maps == true
            or source_map_capabilities.inverse == true
            or source_map_capabilities.forward == true
            or source_map_capabilities.browser_click == true
        )
        and not configured_forward
        and not configured_inverse
    then
        source_sync_provider = source_map_provider
    end
    if
        delegate_to_typst_preview(preview)
        and backend == "typst-preview.nvim"
    then
        capabilities.source_maps = true
        capabilities.inverse = true
        source_sync_provider = "typst-preview.nvim"
        if runtime.command_available("TypstPreviewSyncCursor") then
            capabilities.forward = true
        end
    end

    capabilities.source_sync_provider = source_sync_provider
    capabilities.configured_forward = configured_forward
    capabilities.configured_inverse = configured_inverse
    capabilities.configured_source_map_forward = configured_source_map_forward
    capabilities.configured_source_map_inverse = configured_source_map_inverse

    return capabilities, backend
end

--- Build a normalized unsupported-preview-action result.
---@param project table Project state used for capability lookup.
---@param action string Preview action name.
---@param message string User-facing failure message.
---@return table result Unsupported failure payload.
function M.unsupported(project, action, message)
    local capabilities, backend = M.base(project)
    return {
        ok = false,
        reason = "unsupported",
        message = message,
        provider = backend,
        backend = backend,
        action = action,
        capabilities = capabilities,
    }
end

--- Build a normalized preview callback failure result.
---@param project table Project state used for logging.
---@param action string Preview action name.
---@param err any Callback error object.
---@return table result Callback failure payload.
function M.callback_error(project, action, err)
    log.add("warn", "preview callback failed", {
        main = project and project.main or nil,
        action = action,
        error = err,
    })
    return {
        ok = false,
        reason = "callback_error",
        provider = "callback",
        backend = "callback",
        action = action,
        message = ("Typst preview %s callback failed"):format(action),
        error = err,
    }
end

return M
