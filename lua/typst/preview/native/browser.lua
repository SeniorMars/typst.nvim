local compiler_service = require("typst.project.services.compiler")
local config = require("typst.config")
local events = require("typst.core.events")
local file_shell = require("typst.preview.native.file_shell")
local log = require("typst.core.log")
local native_pending = require("typst.preview.native.pending")
local native_state = require("typst.preview.native.state")
local open_helper = require("typst.core.open")
local preview_export = require("typst.preview.export")
local preview_service = require("typst.project.services.preview")
local session = require("typst.preview.native.session")
local server = require("typst.preview.native.server")
local source_maps = require("typst.preview.source_maps")

local M = {}

function M.effective(raw)
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
    browser = browser or M.effective(config.unsafe_get().preview.browser)
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

function M.cleanup(project)
    local _, file_item = session.clear(project)
    if session.route_count() == 0 then
        server.stop()
    end
    local ok, err = file_shell.stop(file_item)
    if not ok then
        log.add("warn", "failed to stop native preview file shell", {
            main = project.main,
            error = err,
        })
    end
end

local function open_failure(
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

function M.open_output(project, opts, resolved)
    if type(resolved) == "table" and resolved.ok == false then
        return resolved
    end

    opts = opts or {}
    local preview = config.unsafe_get().preview
    local browser = M.effective(preview.browser or {})
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
            token = session.remote_token(browser, preview_server.host),
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
        local failure = open_failure(
            project,
            url,
            path,
            export,
            preview_server and "server" or "file-shell",
            shell_path,
            reason,
            browser
        )
        M.cleanup(project)
        return failure
    end

    vim.g.typst_nvim_last_preview_url = url
    native_state.record(project, "native-browser", opts, {
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

function M.refresh_output(project, result, resolved, refresh_generation)
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
                M.effective(config.unsafe_get().preview.browser or {})
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
        clear = { "last_error" },
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

function M.follow_output(project, next_project, opts, resolved)
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
    local browser = M.effective(config.unsafe_get().preview.browser or {})
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

    native_state.clear_followed_project(project)
    native_state.record(next_project, "native-browser", opts, {
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

function M.refresh(project, result, opts)
    local preview = preview_service.get(project) or {}
    if preview.active_backend ~= "native-browser" then
        return nil
    end

    local browser = M.effective(config.unsafe_get().preview.browser or {})
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
        return M.refresh_output(
            project,
            result,
            resolved_output,
            refresh_generation
        )
    end

    if type(resolved) == "table" and resolved.pending == true then
        local refresh_generation = session.next_refresh_generation(project)
        return native_pending.continuation(resolved, function(resolved_output)
            return M.refresh_output(
                project,
                result,
                resolved_output,
                refresh_generation
            )
        end)
    end

    return continue(resolved)
end

return M
