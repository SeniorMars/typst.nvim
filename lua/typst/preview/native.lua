local compiler_service = require("typst.project.services.compiler")
local config = require("typst.config")
local events = require("typst.core.events")
local file_shell = require("typst.preview.native.file_shell")
local log = require("typst.core.log")
local open_helper = require("typst.core.open")
local preview_export = require("typst.preview.export")
local preview_service = require("typst.project.services.preview")
local session = require("typst.preview.native.session")
local server = require("typst.preview.native.server")
local source_maps = require("typst.preview.source_maps")
local viewer = require("typst.viewer")
local viewer_service = require("typst.project.services.viewer")

local M = {}

local function effective_browser(raw)
    local browser = vim.deepcopy(raw or {})
    local performance = browser.performance or "default"
    if performance == "safari" then
        browser.server = false
        browser.refresh_ms = math.max(tonumber(browser.refresh_ms) or 0, 1500)
        browser.reload_throttle_ms =
            math.max(tonumber(browser.reload_throttle_ms) or 0, 1000)
    elseif performance == "fast" then
        local refresh_ms = tonumber(browser.refresh_ms) or 0
        if refresh_ms == 0 or refresh_ms > 250 then
            browser.refresh_ms = 250
        end
    end
    return browser
end

local function command_labels(commands)
    local labels = {}
    for _, command in ipairs(commands or {}) do
        labels[#labels + 1] = table.concat(command, " ")
    end
    return labels
end

local function browser_url_commands(browser, url)
    if type(browser.commands) ~= "table" then
        return open_helper.browser_commands(browser.app, url)
    end
    local commands = {}
    for _, command in ipairs(browser.commands) do
        local resolved = {}
        local has_url = false
        for _, arg in ipairs(command) do
            local replaced = arg:gsub("{url}", url)
            if replaced ~= arg or replaced == url then
                has_url = true
            end
            resolved[#resolved + 1] = replaced
        end
        if not has_url then
            resolved[#resolved + 1] = url
        end
        commands[#commands + 1] = resolved
    end
    return commands
end

local function open_url(url, project, opts, browser)
    browser = browser or effective_browser(config.unsafe_get().preview.browser)
    if type(browser.open) == "function" then
        local ok, result = pcall(browser.open, url, project, opts)
        if not ok then
            error(
                ("typst.nvim: preview.browser.open failed: %s"):format(result)
            )
        end
        return result == nil and true or result
    end

    local commands = browser_url_commands(browser, url)
    local preflight = open_helper.url_preflight(url, {
        ui = commands == nil,
        commands = commands,
    })
    if not preflight.ok then
        return false, preflight.message or "no URL opener is available"
    end

    local opened, err = open_helper.url(url, {
        ui = commands == nil,
        commands = commands,
    })
    if not opened then
        return false, ("typst.nvim: failed to open preview URL: %s"):format(err)
    end
    return opened
end

local function cleanup_browser(project)
    local _, file_item = session.clear(project)
    local ok, err = file_shell.stop(file_item)
    if not ok then
        log.add("warn", "failed to stop native preview file shell", {
            main = project.main,
            error = err,
        })
    end
end

local function browser_open_failure(
    project,
    url,
    path,
    export,
    transport,
    shell_path,
    err,
    browser
)
    local candidates = {}
    if type(browser.open) ~= "function" then
        local commands = browser_url_commands(browser, url)
        local preflight = open_helper.url_preflight(url, {
            ui = false,
            commands = commands,
        })
        candidates = command_labels(preflight.candidates or commands)
    end
    local result = {
        ok = false,
        reason = "browser_open_failed",
        message = ("Typst browser preview URL could not be opened: %s"):format(
            tostring(err)
        ),
        error = tostring(err),
        url = url,
        output = path,
        export = export,
        transport = transport,
        shell = shell_path,
        opener_candidates = candidates,
    }
    vim.g.typst_nvim_last_preview_url = url
    preview_service.set(project, {
        active = false,
        last_backend = "native-browser-open-failed",
        last_url = url,
        last_failed_url = url,
        last_output = path,
        last_export = export,
        last_transport = transport,
        last_shell = shell_path,
        last_error = result,
    })
    log.add("warn", "native browser preview open failed", {
        main = project.main,
        output = path,
        url = url,
        transport = transport,
        error = tostring(err),
    })
    return result
end

local function record_native(project, backend, opts, fields, active)
    fields = fields or {}
    local cwd = fields.cwd
    local service_fields = vim.deepcopy(fields)
    service_fields.cwd = nil
    require("typst.integrations.typst_preview.state").record(
        project,
        backend,
        opts,
        nil,
        cwd,
        active
    )
    preview_service.set(project, service_fields)
end

local function pending_continuation(pending, continue)
    local callbacks = {}
    local handle = {
        pending = true,
        kind = "preview-native",
        handle = pending,
    }

    function handle:on_finish(callback)
        if type(callback) ~= "function" then
            return self
        end
        if self.result ~= nil then
            pcall(callback, self.result, self)
        else
            callbacks[#callbacks + 1] = callback
        end
        return self
    end

    local function finish(result)
        if handle.result ~= nil then
            return handle.result
        end
        handle.pending = false
        handle.result = continue(result)
        for _, callback in ipairs(callbacks) do
            pcall(callback, handle.result, handle)
        end
        callbacks = {}
        return handle.result
    end

    if type(pending.on_finish) == "function" then
        pending:on_finish(finish)
    end

    function handle.cancel(self_or_opts, maybe_opts)
        local opts = self_or_opts == handle and maybe_opts or self_or_opts
        if handle.result ~= nil then
            return false, handle.result
        end
        if type(pending.cancel) ~= "function" then
            local result = finish({
                ok = false,
                reason = opts and opts.reason or "cancelled",
                stopped = true,
            })
            return true, result
        end
        local ok, stopped, result = pcall(pending.cancel, pending, opts)
        if not ok then
            result = finish({
                ok = false,
                reason = "cancel_failed",
                message = tostring(stopped),
                stopped = false,
            })
            return false, result
        end
        if type(result) ~= "table" or result.pending ~= true then
            result = finish(result or {
                ok = false,
                reason = opts and opts.reason or "cancelled",
                stopped = stopped ~= false,
            })
        end
        return stopped ~= false, result
    end

    return handle
end

local function with_preview_output(project, target, opts, continue)
    local resolved = preview_export.resolve(project, target, nil, opts)
    if type(resolved) == "table" and resolved.pending == true then
        return pending_continuation(resolved, continue)
    end
    return continue(resolved)
end

local function open_viewer_output(project, opts, resolved)
    if type(resolved) == "table" and resolved.ok == false then
        return resolved
    end
    local path = resolved.path
    local export = resolved.export
    path = viewer.open(project, { path = path })
    local viewer_state = viewer_service.get(project) or {}
    record_native(project, "viewer", opts, {
        cwd = viewer_state.cwd,
        last_output = path,
        last_export = export,
        clear = {
            "last_url",
            "active_url",
            "active_output",
            "active_export",
            "active_transport",
            "active_shell",
            "active_server_port",
        },
    }, false)
    events.emit("TypstPreviewOpened", project, {
        backend = "viewer",
        mode = opts and opts.mode or nil,
        output = path,
        export = export,
    })
    return path
end

function M.open_viewer(project, opts)
    return with_preview_output(project, "viewer", opts, function(resolved)
        return open_viewer_output(project, opts, resolved)
    end)
end

local function open_browser_output(project, opts, resolved)
    if type(resolved) == "table" and resolved.ok == false then
        return resolved
    end

    opts = opts or {}
    local preview = config.unsafe_get().preview
    local browser = effective_browser(preview.browser or {})
    local path = resolved.path
    local export = resolved.export
    local id = session.project_id(project)
    local preview_server = nil
    local shell_path = nil
    local url = nil

    if browser.server ~= false then
        local ok, result = xpcall(function()
            return server.start(browser)
        end, debug.traceback)
        if ok then
            preview_server = result
        else
            log.add(
                "warn",
                "native preview server unavailable; using file shell",
                { main = project.main, error = result }
            )
        end
    end

    if preview_server then
        local route = session.set_route(project, {
            host = preview_server.host,
            port = preview_server.port,
            project_key = project.key,
            output = path,
            export = export,
            generation = tostring(
                (compiler_service.get(project) or {}).generation or 0
            ),
            refresh_ms = browser.refresh_ms,
            style = vim.deepcopy(browser.style or {}),
            source_sync = source_maps.route_state(project, {
                output = path,
                generation = tostring(
                    (compiler_service.get(project) or {}).generation or 0
                ),
            }),
        })
        url = session.route_url(route)
    else
        local file_item = file_shell.write(project, path, browser, id)
        file_item.export = export
        session.set_file(project, file_item)
        shell_path = file_item.path
        url = file_item.url
    end

    local ok, opened, open_err = pcall(function()
        return open_url(url, project, opts, browser)
    end)
    if
        not ok
        or opened == false
        or (type(opened) == "table" and opened.ok == false)
    then
        local reason = opened
        if ok then
            if open_err then
                reason = open_err
            elseif type(opened) == "table" then
                reason = opened.message
                    or opened.reason
                    or "preview browser opener returned false"
            else
                reason = "preview browser opener returned false"
            end
        end
        local failure = browser_open_failure(
            project,
            url,
            path,
            export,
            preview_server and "server" or "file-shell",
            shell_path,
            reason,
            browser
        )
        cleanup_browser(project)
        return failure
    end

    vim.g.typst_nvim_last_preview_url = url
    record_native(project, "native-browser", opts, {
        cwd = project.root,
        last_url = url,
        active_url = url,
        last_output = path,
        active_output = path,
        last_export = export,
        active_export = export,
        active_transport = preview_server and "server" or "file-shell",
        last_shell = shell_path,
        active_shell = shell_path,
        last_server_port = preview_server and preview_server.port or nil,
        active_server_port = preview_server and preview_server.port or nil,
    }, true)
    log.add("info", "native browser preview opened", {
        main = project.main,
        output = path,
        url = url,
    })
    events.emit("TypstPreviewOpened", project, {
        backend = "native-browser",
        mode = opts.mode,
        output = path,
        url = url,
        export = export,
    })
    return {
        ok = true,
        provider = "native-browser",
        backend = "native-browser",
        url = url,
        output = path,
        export = export,
    }
end

function M.open_browser(project, opts)
    return with_preview_output(project, "browser", opts, function(resolved)
        return open_browser_output(project, opts, resolved)
    end)
end

function M.open(project, opts)
    opts = opts or {}
    local preview = config.unsafe_get().preview
    local native = opts.native or opts.target or preview.native or "viewer"
    if native == "view" then
        native = "viewer"
    end

    if native == "viewer" then
        return M.open_viewer(project, opts)
    end

    if native == "browser" then
        return M.open_browser(project, opts)
    end

    if native == "auto" then
        local ok, result = xpcall(function()
            return M.open_browser(project, opts)
        end, debug.traceback)
        if
            ok
            and result ~= false
            and not (type(result) == "table" and result.ok == false)
        then
            return result
        end
        log.add("warn", "native browser preview unavailable; using viewer", {
            main = project.main,
            error = type(result) == "table" and result.message or result,
            url = type(result) == "table" and result.url or nil,
        })
        local browser_failure = type(result) == "table"
                and result.ok == false
                and result
            or nil
        local viewer_result = M.open_viewer(project, opts)
        if browser_failure then
            preview_service.set(project, {
                last_error = browser_failure,
                last_failed_url = browser_failure.url,
            })
        end
        return viewer_result
    end

    error('typst.nvim: preview.native must be "browser", "viewer", or "auto"')
end

local function stale_refresh_result(project, result, refresh_generation)
    log.add("debug", "ignored stale native browser preview refresh", {
        main = project.main,
        refresh_generation = refresh_generation,
        current_generation = session.current_refresh_generation(project),
        cycle = result and result.cycle,
    })
    return {
        ok = true,
        stale = true,
        reason = "stale_preview_refresh",
        refresh_generation = refresh_generation,
        current_generation = session.current_refresh_generation(project),
        cycle = result and result.cycle,
    }
end

local function refresh_browser_output(
    project,
    result,
    resolved,
    refresh_generation
)
    if not session.refresh_generation_current(project, refresh_generation) then
        return stale_refresh_result(project, result, refresh_generation)
    end

    if type(resolved) == "table" and resolved.ok == false then
        preview_service.set(project, {
            last_error = resolved,
            last_result = {
                code = result and result.code or nil,
                cycle = result and result.cycle or nil,
            },
        })
        return resolved
    end

    local preview = preview_service.get(project) or {}
    if preview.active_backend ~= "native-browser" then
        return nil
    end

    local path = resolved.path
    local export = resolved.export
    local route = session.route_for_project(project)
    local file_item = session.file_for_project(project)
    if not route and not file_item then
        return nil
    end

    local active_output = preview.active_output
    if path and vim.fn.filereadable(path) == 1 then
        active_output = path
        if route then
            route.output = path
            route.export = export
            route.source_sync = source_maps.route_state(project, {
                output = path,
                generation = session.generation(result),
            })
        end
        if file_item then
            local browser =
                effective_browser(config.unsafe_get().preview.browser or {})
            file_item = file_shell.refresh(
                file_item,
                project,
                path,
                browser,
                session.project_id(project),
                result
            )
            file_item.export = export
            session.set_file(project, file_item)
        end
    end
    if route then
        route.generation = session.generation(result)
    end

    preview_service.set(project, {
        last_backend = "native-browser-refresh",
        last_output = active_output,
        active_output = active_output,
        last_export = export,
        active_export = export,
        last_url = session.browser_url(project),
        active_url = session.browser_url(project),
        active_transport = route and "server" or "file-shell",
        last_result = {
            code = result and result.code or nil,
            cycle = result and result.cycle or nil,
        },
    })
    log.add("debug", "native browser preview refreshed", {
        main = project.main,
        output = active_output,
        generation = route and route.generation or nil,
    })
    return true
end

local function clear_followed_project(project)
    preview_service.set(project, {
        clear = {
            "active_backend",
            "active_mode",
            "active_command",
            "active_cwd",
            "active_url",
            "active_output",
            "active_export",
            "active_transport",
            "active_shell",
            "active_server_port",
            "status",
            "last_result",
            "last_error",
            "stop_prune_reason",
            "stopping",
        },
        active = false,
        last_backend = "native-browser-followed",
    })
end

local function follow_browser_output(project, next_project, opts, resolved)
    if type(resolved) == "table" and resolved.ok == false then
        return resolved
    end

    local preview = preview_service.get(project) or {}
    if preview.active_backend ~= "native-browser" then
        return {
            ok = false,
            reason = "inactive_native_browser",
            message = "No native browser preview route is active to follow the buffer",
        }
    end

    local path = resolved.path
    local export = resolved.export
    local browser = effective_browser(config.unsafe_get().preview.browser or {})
    local route = session.route_for_project(project)
    local file_item = session.file_for_project(project)
    if not route and not file_item then
        return {
            ok = false,
            reason = "missing_native_route",
            message = "Native browser preview route is missing",
        }
    end

    local generation =
        tostring((compiler_service.get(next_project) or {}).generation or 0)
    local source_sync = source_maps.route_state(next_project, {
        output = path,
        generation = generation,
    })

    if route then
        session.reassign(project, next_project, {
            output = path,
            export = export,
            generation = generation,
            source_sync = source_sync,
            forward_target = nil,
        })
    end
    if file_item then
        file_item = file_shell.refresh(
            file_item,
            next_project,
            path,
            browser,
            file_item.id or session.project_id(project),
            { generation = generation }
        )
        file_item.export = export
        file_item.project_key = next_project.key
        file_item.main = next_project.main
        file_item.root = next_project.root
    end

    clear_followed_project(project)
    record_native(next_project, "native-browser", opts, {
        cwd = next_project.root,
        last_url = session.browser_url(next_project),
        active_url = session.browser_url(next_project),
        last_output = path,
        active_output = path,
        last_export = export,
        active_export = export,
        active_transport = route and "server" or "file-shell",
        last_shell = file_item and file_item.path or nil,
        active_shell = file_item and file_item.path or nil,
        last_server_port = route and route.port or nil,
        active_server_port = route and route.port or nil,
        followed_from = project.key,
    }, true)
    events.emit("TypstPreviewOpened", next_project, {
        backend = "native-browser",
        mode = opts and opts.mode or nil,
        output = path,
        url = session.browser_url(next_project),
        export = export,
        follow_buffer = true,
        previous_project = project.key,
    })
    log.add("info", "native browser preview followed active buffer", {
        from = project.main,
        to = next_project.main,
        output = path,
    })
    return {
        ok = true,
        provider = "native-browser",
        backend = "native-browser",
        followed = true,
        url = session.browser_url(next_project),
        output = path,
        export = export,
    }
end

function M.follow_buffer(project, next_project, opts)
    if not project or not next_project or project.key == next_project.key then
        return nil
    end
    opts = vim.tbl_extend("force", {
        follow_buffer = true,
    }, opts or {})
    return with_preview_output(next_project, "browser", opts, function(resolved)
        return follow_browser_output(project, next_project, opts, resolved)
    end)
end

function M.refresh(project, result, opts)
    local preview = preview_service.get(project) or {}
    if preview.active_backend ~= "native-browser" then
        return nil
    end

    local browser = effective_browser(config.unsafe_get().preview.browser or {})
    local throttle_ms = tonumber(browser.reload_throttle_ms) or 0
    if throttle_ms > 0 and not (result and result.manual == true) then
        local now = (vim.uv or vim.loop).hrtime()
        local last = tonumber(preview.last_browser_refresh_at_ns) or 0
        local elapsed_ms = last > 0 and ((now - last) / 1000000) or math.huge
        if elapsed_ms < throttle_ms then
            local remaining = math.ceil(throttle_ms - elapsed_ms)
            preview_service.set(project, {
                last_backend = "native-browser-refresh-throttled",
                last_browser_refresh_skipped_ms = remaining,
                last_result = {
                    code = result and result.code or nil,
                    cycle = result and result.cycle or nil,
                },
            })
            log.add("debug", "native browser preview refresh throttled", {
                main = project.main,
                remaining_ms = remaining,
                throttle_ms = throttle_ms,
            })
            return {
                ok = true,
                skipped = true,
                throttled = true,
                reason = "browser_reload_throttled",
                remaining_ms = remaining,
                throttle_ms = throttle_ms,
            }
        end
        preview_service.set(project, {
            last_browser_refresh_at_ns = now,
        })
    end

    local resolved = preview_export.resolve(project, "browser", nil, opts)
    if
        type(resolved) == "table"
        and resolved.ok == false
        and resolved.reason == "active_output"
    then
        log.add("debug", "native browser preview refresh already active", {
            main = project.main,
            active_output = resolved.active_output,
        })
        return vim.tbl_extend("force", resolved, {
            skipped = true,
            refresh_busy = true,
        })
    end

    local function continue(resolved_output)
        local refresh_generation = session.next_refresh_generation(project)
        return refresh_browser_output(
            project,
            result,
            resolved_output,
            refresh_generation
        )
    end

    if type(resolved) == "table" and resolved.pending == true then
        local refresh_generation = session.next_refresh_generation(project)
        return pending_continuation(resolved, function(resolved_output)
            return refresh_browser_output(
                project,
                result,
                resolved_output,
                refresh_generation
            )
        end)
    end

    return continue(resolved)
end

function M.stop(project)
    cleanup_browser(project)
    return true
end

function M.browser_url(project)
    return session.browser_url(project)
end

return M
