local config = require("typst.config")
local events = require("typst.core.events")
local log = require("typst.core.log")
local provider_adapter = require("typst.integrations.provider_adapter")
local providers = require("typst.integrations.providers")
local location = require("typst.integrations.typst_preview.location")
local preview_service = require("typst.project.services.preview")

local M = {}

local function source_maps_config()
    return (config.unsafe_get().preview or {}).source_maps or {}
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

function M.provider_label()
    local source_maps = source_maps_config()
    return provider_label(source_maps.provider) or "source-maps"
end

local function module_provider(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local builtins = {
        ["typst-query"] = "typst.preview.source_maps.typst_query",
        ["local-text"] = "typst.preview.source_maps.typst_query",
        ["local_text"] = "typst.preview.source_maps.typst_query",
    }
    name = builtins[name] or name
    local ok, loaded = pcall(require, name)
    if ok and (type(loaded) == "table" or type(loaded) == "function") then
        return loaded
    end
    return nil
end

local function resolve_provider(source_maps)
    source_maps = source_maps or source_maps_config()
    local provider = source_maps.provider
    provider = providers.resolve("source_map", provider)
    if type(provider) == "string" then
        provider = module_provider(provider)
    end
    if type(provider) == "function" or type(provider) == "table" then
        return provider
    end
    return nil
end

local function provider_project(project)
    return providers.project_context(project)
end

local function provider_name(provider)
    if type(provider) == "table" and type(provider.name) == "string" then
        return provider.name
    end
    return type(provider) == "function" and "callback" or "table"
end

local function invoke_provider(project, methods, request, callback)
    local provider = resolve_provider()
    if not provider then
        return nil
    end

    return provider_adapter.invoke(
        provider,
        methods,
        provider_project(project),
        request,
        {
            kind = "source_map",
            provider_name = provider_name(provider),
            args = { provider_project(project), request },
            on_result = callback,
            invalid_result_message = "Source-map provider returned no result",
        }
    )
end

local function method_exists(provider, names)
    if type(provider) == "function" then
        return true
    end
    if type(provider) ~= "table" then
        return false
    end
    for _, name in ipairs(names) do
        if type(provider[name]) == "function" then
            return true
        end
    end
    return false
end

local function provider_capabilities(provider, project, request)
    if
        type(provider) ~= "table"
        or type(provider.capabilities) ~= "function"
    then
        return nil
    end

    local ok, capabilities = pcall(
        provider.capabilities,
        project and provider_project(project) or nil,
        request or {}
    )
    if ok and type(capabilities) == "table" then
        return capabilities
    end
    return nil
end

local function merge_provider_capabilities(
    capabilities,
    provider,
    declared_capabilities
)
    if method_exists(provider, { "forward", "run" }) then
        capabilities.forward = true
    end
    if method_exists(provider, { "inverse", "resolve", "run" }) then
        capabilities.inverse = true
    end
    if method_exists(provider, { "browser_inverse", "resolve", "run" }) then
        capabilities.browser_click = true
    end
    if method_exists(provider, { "generate", "resolve", "run" }) then
        capabilities.source_maps = true
    end

    local declared = declared_capabilities
    if declared then
        for _, capability in ipairs({
            "forward",
            "inverse",
            "source_maps",
            "browser_click",
        }) do
            if declared[capability] ~= nil then
                capabilities[capability] = declared[capability] == true
            end
        end
    end
end

local function additive_capabilities(source_maps)
    local capabilities = {
        forward = false,
        inverse = false,
        source_maps = false,
        browser_click = false,
    }
    for capability, enabled in pairs(source_maps.capabilities or {}) do
        if enabled == true then
            capabilities[capability] = true
        end
    end
    return capabilities
end

local function request_base(project, opts)
    opts = opts or {}
    return vim.tbl_extend("force", {
        main = project.main,
        root = project.root,
        output = opts.output,
        generation = opts.generation,
    }, opts)
end

local function active_output_for_project(project)
    if type(project) ~= "table" then
        return nil
    end
    local ok, session = pcall(require, "typst.preview.native.session")
    if not ok then
        return nil
    end
    local state = session.project_state(project)
    return state and state.output or nil
end

local function active_preview_context(project)
    if type(project) ~= "table" then
        return {}
    end
    local ok, session = pcall(require, "typst.preview.native.session")
    if not ok then
        return {}
    end
    local route = session.route_for_project(project)
    if route then
        return {
            output = route.output,
            generation = route.generation,
        }
    end
    local file = session.file_for_project(project)
    if file then
        return {
            output = file.output,
            generation = file.generation,
        }
    end
    return {}
end

local function set_forward_target(project, target)
    if type(target) ~= "table" or target.ok == false then
        return
    end
    if target.pending == true then
        return
    end
    local ok, session = pcall(require, "typst.preview.native.session")
    if ok then
        session.set_forward_target(project, target)
    end
end

local function publish_forward_target(project, result)
    if type(result) == "table" and result.pending == true then
        if type(result.on_finish) == "function" then
            result:on_finish(function(target)
                set_forward_target(project, target)
            end)
        end
    else
        set_forward_target(project, result)
    end
end

function M.capabilities(project, opts)
    opts = opts or {}
    local source_maps = source_maps_config()
    local capabilities = additive_capabilities(source_maps)
    local provider = resolve_provider(source_maps)
    local request = nil

    if type(source_maps.forward) == "function" then
        capabilities.forward = true
    end
    if type(source_maps.inverse) == "function" then
        capabilities.inverse = true
    end
    if provider then
        if project then
            request = request_base(
                project,
                vim.tbl_extend("force", {
                    output = opts.output or active_output_for_project(project),
                }, opts)
            )
        else
            request = vim.tbl_extend("force", {
                output = opts.output,
                generation = opts.generation,
            }, opts)
        end
        merge_provider_capabilities(
            capabilities,
            provider,
            provider_capabilities(provider, project, request)
        )
    end

    capabilities.provider = provider_label(source_maps.provider)
        or (provider and provider_name(provider))
        or nil
    return capabilities
end

function M.forward(project, position, opts)
    local source_maps = source_maps_config()
    if type(source_maps.forward) == "function" then
        local result = source_maps.forward(project, position, opts or {})
        publish_forward_target(project, result)
        return result
    end

    local active = active_preview_context(project)
    opts = opts or {}
    local result = invoke_provider(
        project,
        { "forward", "run" },
        request_base(project, {
            action = "forward",
            output = opts.output or active.output,
            generation = opts.generation or active.generation,
            position = vim.deepcopy(position),
            line = position.line,
            column = position.column,
            opts = vim.deepcopy(opts or {}),
        })
    )

    publish_forward_target(project, result)
    return result
end

function M.inverse(project, source_location, opts)
    local source_maps = source_maps_config()
    if type(source_maps.inverse) == "function" then
        return source_maps.inverse(project, source_location, opts or {})
    end

    return invoke_provider(
        project,
        { "inverse", "resolve", "run" },
        request_base(project, {
            action = "inverse",
            location = vim.deepcopy(source_location),
            path = source_location.path,
            line = source_location.line,
            column = source_location.column,
            opts = vim.deepcopy(opts or {}),
        })
    )
end

local function project_from_route(route)
    local all = require("typst.project").all()
    if route.project_key and all[route.project_key] then
        return all[route.project_key]
    end
    for _, project in pairs(all) do
        if project.main == route.main and project.root == route.root then
            return project
        end
    end
    return {
        key = route.project_key or route.id,
        root = route.root,
        main = route.main,
    }
end

local function number_field(value)
    local numeric = tonumber(value)
    return numeric
end

local function normalize_location(project, result)
    if type(result) ~= "table" then
        return nil
    end
    local source = result.location or result.source or result
    local path = source.path or source.file or source.filename
    local line = tonumber(source.line or source.lnum)
    local column = tonumber(source.column or source.col)
    if not path or not line then
        return nil
    end
    return {
        path = require("typst.core.util").resolve_path(path, project.root),
        line = line,
        column = column or 1,
    }
end

local function open_browser_result(project, request, result)
    if type(result) == "table" and result.ok == false then
        return result
    end
    if result == false then
        return {
            ok = false,
            reason = "source_sync_declined",
        }
    end

    local resolved = normalize_location(project, result)
    if not resolved then
        return {
            ok = false,
            reason = "missing_source_location",
            message = "Source-map provider did not return a source location",
        }
    end

    local function open_resolved()
        local opened = location.open_source(resolved, { open = true })
        if type(opened) == "table" and opened.ok == false then
            return opened
        end

        preview_service.set(project, {
            last_backend = (request.provider or "source-map")
                .. "-browser-inverse",
        })
        events.emit("TypstPreviewInverse", project, {
            backend = request.provider or "source-map",
            path = resolved.path,
            line = resolved.line,
            column = resolved.column,
            source_sync = "browser-inverse",
            output = request.output,
            page = request.page,
            x = request.x,
            y = request.y,
        })
        return vim.tbl_extend("force", {
            ok = true,
            source_sync = "browser-inverse",
        }, resolved)
    end

    if vim.in_fast_event and vim.in_fast_event() then
        vim.schedule(function()
            local opened = open_resolved()
            if type(opened) == "table" and opened.ok == false then
                log.add("warn", "native browser source-sync failed", {
                    main = project.main,
                    reason = opened.reason,
                    message = opened.message,
                })
            end
        end)
        return vim.tbl_extend("force", {
            ok = true,
            scheduled = true,
            source_sync = "browser-inverse",
        }, resolved)
    end

    return open_resolved()
end

local function on_pending_browser_result(project, request, pending)
    if type(pending) ~= "table" or type(pending.on_finish) ~= "function" then
        return
    end
    pending:on_finish(function(result)
        local opened = open_browser_result(project, request, result)
        if type(opened) == "table" and opened.ok == false then
            log.add("warn", "native browser source-sync failed", {
                main = project.main,
                reason = opened.reason,
                message = opened.message,
            })
        end
    end)
end

function M.browser_inverse(route, params)
    local project = project_from_route(route)
    local provider = M.provider_label()
    local request = request_base(project, {
        action = "browser_inverse",
        provider = provider,
        output = route.output,
        output_name = route.output and require("typst.core.util").basename(
            route.output
        ) or nil,
        generation = route.generation,
        page = number_field(params.page) or 1,
        x = number_field(params.x),
        y = number_field(params.y),
        client_x = number_field(params.client_x),
        client_y = number_field(params.client_y),
        viewport_width = number_field(params.viewport_width),
        viewport_height = number_field(params.viewport_height),
        target = params.target,
        event = params.event or "click",
        transport = "server",
    })

    local result = invoke_provider(
        project,
        { "browser_inverse", "resolve", "inverse", "run" },
        request
    )
    if type(result) == "table" and result.pending == true then
        on_pending_browser_result(project, request, result)
        return {
            ok = true,
            pending = true,
            source_sync = "browser-inverse",
        }
    end
    if result == nil then
        return {
            ok = false,
            reason = "unsupported",
            message = "No source-map provider is configured for browser inverse sync",
        }
    end

    return open_browser_result(project, request, result)
end

function M.route_state(project, opts)
    local capabilities = M.capabilities(project, opts)
    local output = opts and opts.output or nil
    local output_format = type(output) == "string"
            and vim.fn.fnamemodify(output, ":e"):lower()
        or nil
    local available = capabilities.forward
        or capabilities.inverse
        or capabilities.source_maps
        or capabilities.browser_click
    local message = nil
    if not available then
        local provider = capabilities.provider or "none"
        if output_format == "pdf" then
            message =
                "PDF preview has no SyncTeX-style source sync; use SVG preview or a source-map provider"
        elseif provider == "typst-query" then
            message =
                "typst-query source sync is SVG-first; use an SVG preview export"
        elseif provider == "none" then
            message = "No source-map provider is configured"
        else
            message = "Source sync is unavailable for this preview output"
        end
    end

    return {
        provider = capabilities.provider or "none",
        forward = capabilities.forward == true,
        inverse = capabilities.inverse == true,
        source_maps = capabilities.source_maps == true,
        browser_click = capabilities.browser_click == true,
        available = available == true,
        output_format = output_format,
        message = message,
    }
end

return M
