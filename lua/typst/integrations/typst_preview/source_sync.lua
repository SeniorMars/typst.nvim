local config = require("typst.config")
local events = require("typst.core.events")
local location = require("typst.integrations.typst_preview.location")
local log = require("typst.core.log")
local preview_service = require("typst.project.services.preview")
local preview_capabilities =
    require("typst.integrations.typst_preview.capabilities")
local source_map_service = require("typst.preview.source_maps")
local runtime = require("typst.integrations.typst_preview.runtime")

local M = {}

local unsupported = preview_capabilities.unsupported
local callback_error = preview_capabilities.callback_error

local function delegate_to_typst_preview(preview)
    return preview.provider == "typst-preview.nvim"
end

local function failed_result(result)
    return type(result) == "table" and result.ok == false
end

--- Forward-search through the configured Typst preview backend.
---@param project table Project state whose preview/source context is used.
---@param opts? table Forward-search options.
---@return table|boolean result Backend result or unsupported/callback failure payload.
function M.forward(project, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local forward = preview.forward
    local callback_backend = "callback"
    local source_map_capabilities = source_map_service.capabilities(project)
    local position = location.current_position(opts)
    if not position then
        return {
            ok = false,
            reason = "position_required",
            message = "Preview forward search requires a source position for the target buffer",
        }
    end

    if type(forward) ~= "function" and source_map_capabilities.forward then
        forward = function(project_, position_, opts_)
            return source_map_service.forward(project_, position_, opts_)
        end
        callback_backend = source_map_capabilities.provider
            or source_map_service.provider_label()
    end

    if type(forward) ~= "function" then
        if
            delegate_to_typst_preview(preview)
            and runtime.command_available("TypstPreviewSyncCursor")
        then
            local command = "TypstPreviewSyncCursor"
            local cwd = runtime.run_at_position(project, command, position)
            preview_service.set(project, {
                last_backend = "typst-preview.nvim-forward-command",
                last_command = { command },
                last_cwd = cwd,
            })
            log.add("info", "preview forwarded through typst-preview.nvim", {
                main = project.main,
                line = position.line,
                column = position.column,
                command = command,
            })
            events.emit("TypstPreviewForwarded", project, {
                backend = "typst-preview.nvim",
                command = { command },
                line = position.line,
                column = position.column,
                source_sync = "forward",
            })
            return true
        end

        local result = unsupported(
            project,
            "forward",
            "No Typst preview forward-search callback is configured"
        )
        log.add("warn", "preview forward unsupported", {
            main = project.main,
            backend = result.backend,
            capabilities = result.capabilities,
        })
        return result
    end

    local ok, result = pcall(forward, project, position, opts)
    if not ok then
        return callback_error(project, "forward", result)
    end
    if failed_result(result) then
        return result
    end
    if result ~= false then
        preview_service.set(project, {
            clear = { "last_command", "last_cwd" },
            last_backend = callback_backend .. "-forward",
        })
        log.add("info", "preview forwarded", {
            main = project.main,
            line = position.line,
            column = position.column,
            backend = callback_backend,
        })
        events.emit("TypstPreviewForwarded", project, {
            backend = callback_backend,
            line = position.line,
            column = position.column,
            source_sync = "forward",
        })
    end

    return result
end

--- Inverse-search through the configured Typst preview backend.
---@param project table Project state whose preview/source context is used.
---@param opts? table Inverse-search options.
---@return table|boolean result Backend result or unsupported/callback failure payload.
function M.inverse(project, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local inverse = preview.inverse
    local callback_backend = "callback"
    local source_map_capabilities = source_map_service.capabilities(project)
    local capability_set, backend = preview_capabilities.base(project)
    local source_location = location.from_opts(project, opts)

    if type(inverse) ~= "function" and source_map_capabilities.inverse then
        inverse = function(project_, source_location_, opts_)
            return source_map_service.inverse(project_, source_location_, opts_)
        end
        callback_backend = source_map_capabilities.provider
            or source_map_service.provider_label()
    end

    if type(inverse) == "function" then
        local ok, result = pcall(inverse, project, source_location, opts)
        if not ok then
            return callback_error(project, "inverse", result)
        end
        if failed_result(result) then
            return result
        end
        if result ~= false then
            preview_service.set(project, {
                clear = { "last_command", "last_cwd" },
                last_backend = callback_backend .. "-inverse",
            })
            events.emit("TypstPreviewInverse", project, {
                backend = callback_backend,
                path = source_location.path,
                line = source_location.line,
                column = source_location.column,
                source_sync = "inverse",
            })
        end
        return result
    end

    if not capability_set.inverse then
        local result = unsupported(
            project,
            "inverse",
            "No Typst preview inverse-search backend is configured"
        )
        log.add("warn", "preview inverse unsupported", {
            main = project.main,
            backend = result.backend,
            capabilities = result.capabilities,
        })
        return result
    end

    local result = location.open_source(source_location, opts)
    if failed_result(result) then
        return result
    end

    preview_service.set(project, {
        last_backend = backend .. "-inverse",
    })
    log.add("info", "preview inverse jump", {
        main = project.main,
        path = source_location.path,
        line = source_location.line,
        column = source_location.column,
        backend = backend,
    })
    events.emit("TypstPreviewInverse", project, {
        backend = backend,
        path = source_location.path,
        line = source_location.line,
        column = source_location.column,
        source_sync = "inverse",
    })
    return result
end

--- Return source-sync capabilities for the configured Typst preview backend.
---@param project table Project state whose preview state may affect backend selection.
---@return table capabilities Capability snapshot.
function M.capabilities(project)
    local capability_set, backend = preview_capabilities.base(project)
    local preview = config.unsafe_get().preview
    local source_maps = preview.source_maps or {}
    return {
        provider = backend,
        backend = backend,
        forward = capability_set.forward,
        inverse = capability_set.inverse,
        source_maps = capability_set.source_maps,
        browser_click = capability_set.browser_click,
        configured_forward = type(preview.forward) == "function",
        configured_inverse = type(preview.inverse) == "function",
        configured_source_map_forward = type(source_maps.forward) == "function",
        configured_source_map_inverse = type(source_maps.inverse) == "function",
        source_sync_provider = capability_set.source_sync_provider,
        capabilities = capability_set,
    }
end

return M
