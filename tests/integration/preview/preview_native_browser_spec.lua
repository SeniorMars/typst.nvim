local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local html = require("typst.preview.native.html")
local native = require("typst.preview.native")
local preview_service = require("typst.project.services.preview")
local project_store = require("typst.project.store")
local resource_session = require("typst.resources.session")
local typst = require("typst")
local util = require("typst.core.util")

typst.reset()

local opened_url = nil
local refreshes = 0
local refresh_callbacks = 0
local stop_callbacks = 0

local function test_cache_dir(name)
    return typst_test_cache_path(name)
end

local function live_project(snapshot)
    return assert(project_store.get(snapshot.key), "live project")
end

local escaped_shell = html.file_shell({
    main = "main.typ",
    output = "bad <img src=x onerror=alert(1)>.pdf",
    state_url = "file:///tmp/state.js",
})
assert(
    not escaped_shell:find("bad <img", 1, true),
    "file shell should escape output names"
)
assert(
    escaped_shell:find("bad &lt;img", 1, true),
    "file shell should include escaped output name"
)

local style_path = typst_test_config_path("preview.css")
vim.fn.mkdir(util.dirname(style_path), "p")
vim.fn.writefile(
    { "#viewport { outline: 1px solid rgb(1, 2, 3); }" },
    style_path
)
local styled_shell = html.file_shell({
    root = root,
    main = "main.typ",
    output = "main.pdf",
    state_url = "file:///tmp/state.js",
    style = {
        variables = {
            bg = "#101010",
            ["--custom-preview-accent"] = "#ffcc00",
        },
        css = "header { min-height: 32px; }",
        css_path = style_path,
    },
})
assert(
    styled_shell:find("%-%-typst%-preview%-bg:%s*#101010;"),
    "browser shell should include configured CSS variables"
)
assert(
    styled_shell:find("%-%-custom%-preview%-accent:%s*#ffcc00;"),
    "browser shell should include custom CSS variable names"
)
assert(
    styled_shell:find("outline: 1px solid rgb%(1, 2, 3%);"),
    "browser shell should include configured CSS file contents"
)
assert(
    styled_shell:find("header { min%-height: 32px; }", 1, false),
    "browser shell should include configured inline CSS"
)

local forward_only_shell = html.server_shell({
    main = "main.typ",
    output = "main.svg",
    refresh_ms = 25,
    source_sync = {
        provider = "forward-only",
        forward = true,
        browser_click = false,
    },
})
assert(
    forward_only_shell:find("forward sync available", 1, true),
    "browser shell should distinguish forward sync from browser click sync"
)
assert(
    forward_only_shell:find("browser click sync unavailable", 1, true),
    "browser shell should label disabled click sync precisely"
)

typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-browser-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        refresh = function()
            refresh_callbacks = refresh_callbacks + 1
            return true
        end,
        stop = function()
            stop_callbacks = stop_callbacks + 1
            return true
        end,
        browser = {
            server = false,
            output_dir = test_cache_dir("preview-native-browser-shell"),
            refresh_ms = 25,
            open = function(url)
                opened_url = url
                return true
            end,
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = live_project(typst.project.set_main(main))

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before native browser preview")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before native browser preview"
)

local opened_event = nil
local stopped_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewOpened",
    callback = function(args)
        opened_event = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewStopped",
    callback = function(args)
        stopped_event = args.data
    end,
})

local result = typst.viewer.preview({ mode = "document" })
assert(result and result.ok == true, "native browser preview should open")
assert(
    opened_url and opened_url:match("^file://"),
    "native browser preview should open a file shell when server=false"
)
assert(
    result.url == opened_url,
    "native browser preview should report the opened URL"
)
assert(
    native.browser_url(project) == opened_url,
    "native browser preview should keep a route for the project"
)
assert(
    typst_test_preview(project).active == true,
    "native browser preview should be tracked as active"
)
assert(
    typst_test_preview(project).active_backend == "native-browser",
    "native browser preview should record active backend"
)
assert(
    opened_event and opened_event.backend == "native-browser",
    "native browser preview should emit open event"
)
assert(
    opened_event.url == opened_url,
    "native browser preview event should include URL"
)

local capabilities = typst.viewer.preview_capabilities()
assert(
    capabilities.backend == "native-browser",
    "native browser capabilities should report backend"
)
assert(
    capabilities.source_maps == false and capabilities.forward == false,
    "native browser should not claim source-map support"
)
assert(
    capabilities.source_sync_provider == "none",
    "native browser should not claim a source-sync provider"
)

local preview_backend = require("typst.integrations.typst_preview")
local refresh_callbacks_before_native = refresh_callbacks
preview_service.set(project, {
    last_error = {
        reason = "stale_refresh_error",
        message = "synthetic stale refresh failure",
    },
})
local refreshed = preview_backend.refresh(project, {
    code = 0,
    generation = 42,
}, {
    source = "compile",
})
assert(
    refreshed and refreshed.native == true and refreshed.callback == true,
    "native browser preview should refresh native state and callback"
)
assert(
    refresh_callbacks == refresh_callbacks_before_native + 1,
    "native refresh callback should run"
)
assert(
    typst_test_preview(project).last_backend == "native-browser-refresh",
    "native browser refresh should update preview state"
)
assert(
    typst_test_preview(project).last_error == nil,
    "successful native browser refresh should clear stale refresh errors"
)
for _, blocker in ipairs(resource_session.blockers(project)) do
    assert(
        blocker.kind ~= "preview_failed",
        "successful native browser refresh should clear preview_failed blockers"
    )
end
refreshes = refreshes + 1

local shell_path = typst_test_preview(project).active_shell
assert(shell_path, "file shell preview should record active shell path")
local state_path = shell_path:gsub("%.html$", ".state.js")
local active_state_text = table.concat(vim.fn.readfile(state_path), "\n")
local file_item =
    require("typst.preview.native.session").file_for_project(project)
assert(
    file_item and tostring(file_item.generation) == "42",
    "file shell session should store the refreshed preview generation"
)
assert(
    active_state_text:find('"generation":"42"', 1, true)
        or active_state_text:find('"generation":42', 1, true),
    "file shell state should expose the refreshed preview generation"
)
assert(
    active_state_text:find('"output_format":"pdf"', 1, true),
    "file shell state should expose the preview output format"
)
assert(
    active_state_text:find('"available":false', 1, true),
    "PDF file shell state should not claim source-sync availability"
)
assert(
    active_state_text:find("PDF preview has no SyncTeX%-style source sync"),
    "PDF file shell state should explain source-sync limitations"
)

assert(
    typst.viewer.preview_stop({ notify = false }) == true,
    "native browser preview should stop"
)
assert(stop_callbacks == 1, "native stop callback should run")
assert(
    typst_test_preview(project).active == false,
    "native browser preview stop should clear active state"
)
assert(
    native.browser_url(project) == nil,
    "native browser preview stop should remove the route"
)
assert(
    stopped_event and stopped_event.backend == "native-browser",
    "native browser preview stop should emit event"
)
local state_text = table.concat(vim.fn.readfile(state_path), "\n")
assert(
    state_text:find('"ok":false', 1, true),
    "file shell state should be marked stopped after preview stop"
)
local shell_text = table.concat(vim.fn.readfile(shell_path), "\n")
assert(
    shell_text:find("Preview stopped", 1, true),
    "file shell HTML should be overwritten after preview stop"
)
assert(refreshes == 1, "native browser refresh assertion should run")

typst.reset({ force = true })

local pending_stop_url = nil
local finish_native_colon_stop = nil
typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-browser-pending-stop-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        stop = function()
            local handle = {
                pending = true,
                on_finish_style = "colon",
            }
            function handle:on_finish(callback)
                finish_native_colon_stop = callback
                return self
            end
            return handle
        end,
        browser = {
            server = false,
            output_dir = test_cache_dir(
                "preview-native-browser-pending-stop-shell"
            ),
            open = function(url)
                pending_stop_url = url
                return true
            end,
        },
    },
})

vim.cmd.edit(main)
local pending_stop_project = live_project(typst.project.set_main(main))
done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before pending native stop")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before pending native stop"
)

local pending_native = typst.viewer.preview({ mode = "document" })
assert(
    pending_native and pending_native.ok == true,
    "pending native should open"
)
local native_stop = typst.viewer.preview_stop({ notify = false })
assert(
    native_stop and native_stop.pending == true,
    "native browser stop should expose pending callback handle"
)
assert(
    type(finish_native_colon_stop) == "function",
    "native browser stop should subscribe to method-style stop handle"
)
assert(
    native.browser_url(pending_stop_project) == pending_stop_url,
    "native browser route should stay active while stop callback is pending"
)
finish_native_colon_stop({ ok = true, stopped = true })
assert(
    native_stop.pending == false,
    "native browser stop handle should finish after callback completion"
)
assert(
    native.browser_url(pending_stop_project) == nil,
    "native browser route should be removed after pending stop finishes"
)
assert(
    typst_test_preview(pending_stop_project).active == false,
    "native browser preview state should clear after pending stop finishes"
)

typst.reset({ force = true })

local nil_refresh_url = nil
local nil_refresh_pending_export = nil
local nil_refresh_export_calls = 0
local nil_refresh_provider = function(_project, opts, callback)
    nil_refresh_export_calls = nil_refresh_export_calls + 1
    vim.fn.writefile({
        ('<svg xmlns="http://www.w3.org/2000/svg"><text>%d</text></svg>'):format(
            nil_refresh_export_calls
        ),
    }, opts.output_path)
    local result = {
        ok = true,
        path = opts.output_path,
        artifacts = {
            {
                path = opts.output_path,
                format = "svg",
            },
        },
    }
    if nil_refresh_export_calls == 1 then
        if callback then
            callback(result)
        end
        return result
    end

    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(on_finish)
        self._on_finish = on_finish
        return self
    end
    function handle:finish()
        self.pending = false
        if callback then
            callback(result)
        end
        if self._on_finish then
            self._on_finish(result)
        end
        return result
    end
    nil_refresh_pending_export = handle
    return handle
end

typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-browser-nil-refresh-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        browser = {
            server = false,
            output_dir = test_cache_dir(
                "preview-native-browser-nil-refresh-shell"
            ),
            export = {
                mode = "provider",
                provider = nil_refresh_provider,
                output_format = "svg",
            },
            open = function(url)
                nil_refresh_url = url
                return true
            end,
        },
    },
})

vim.cmd.edit(main)
local nil_refresh_project = live_project(typst.project.set_main(main))
local nil_refresh_open = typst.viewer.preview({ mode = "document" })
assert(
    nil_refresh_open and nil_refresh_open.ok == true,
    "nil refresh native browser should open"
)
assert(
    native.browser_url(nil_refresh_project) == nil_refresh_url,
    "nil refresh route should be active before refresh"
)

local nil_refresh = native.refresh(nil_refresh_project, {
    code = 0,
    cycle = 1,
}, {})
assert(
    nil_refresh and nil_refresh.pending == true,
    "nil refresh should expose a pending continuation"
)
assert(
    nil_refresh_pending_export,
    "nil refresh should hold a pending export handle"
)
local nil_refresh_callbacks = 0
nil_refresh:on_finish(function(result, handle)
    nil_refresh_callbacks = nil_refresh_callbacks + 1
    assert(result == nil, "stopped native browser refresh should finish nil")
    assert(handle == nil_refresh, "nil refresh callback should receive handle")
end)

typst.viewer.preview_stop({ notify = false })
assert(
    native.browser_url(nil_refresh_project) == nil,
    "nil refresh route should be removed before pending export resolves"
)
nil_refresh_pending_export:finish()
assert(nil_refresh.pending == false, "nil refresh should clear pending")
assert(nil_refresh.finished == true, "nil refresh should mark finished")
assert(
    nil_refresh_callbacks == 1,
    "nil refresh should notify callbacks exactly once"
)
local late_nil_refresh_called = false
nil_refresh:on_finish(function(result)
    late_nil_refresh_called = true
    assert(result == nil, "late nil refresh callback should receive nil")
end)
assert(
    late_nil_refresh_called == true,
    "late nil refresh callback should run immediately"
)
nil_refresh.finish({ again = true }, "duplicate")
assert(
    nil_refresh_callbacks == 1,
    "duplicate nil refresh finish should not rerun callbacks"
)

typst.reset({ force = true })

local failed_open_url = nil
local viewer_opened = nil
typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-browser-auto-output"),
    compile = {
        deps = false,
    },
    viewer = {
        open = function(path)
            viewer_opened = path
            return true
        end,
    },
    preview = {
        native = "auto",
        browser = {
            server = false,
            output_dir = test_cache_dir("preview-native-browser-failed-shell"),
            open = function(url)
                failed_open_url = url
                error("synthetic browser open failure")
            end,
        },
    },
})

vim.cmd.edit(main)
local fallback_project = live_project(typst.project.set_main(main))
done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before native auto fallback")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before native auto fallback"
)

local fallback = typst.viewer.preview({ mode = "document" })
assert(fallback == typst_test_compiler(fallback_project).output)
assert(failed_open_url, "native auto should try browser preview first")
assert(
    viewer_opened == typst_test_compiler(fallback_project).output,
    "native auto should fall back to viewer after browser open failure"
)
assert(
    native.browser_url(fallback_project) == nil,
    "failed browser open should clean up native browser session"
)
local fallback_preview = typst_test_preview(fallback_project)
assert(
    fallback_preview.last_error
        and fallback_preview.last_error.reason == "browser_open_failed",
    "failed browser open should keep a structured failure"
)
assert(
    fallback_preview.last_error.url == failed_open_url,
    "failed browser open should expose the browser URL"
)
assert(
    fallback_preview.last_failed_url == failed_open_url,
    "failed browser open should keep the failed URL for status reports"
)
local failed_status = typst.viewer.preview_status({
    echo = false,
    notify = false,
})
assert(
    table.concat(failed_status.lines, "\n"):find(failed_open_url, 1, true),
    "preview status should include the failed browser URL"
)
local original_setreg = vim.fn.setreg
local copied_register = nil
local copied_value = nil
vim.fn.setreg = function(register, value)
    copied_register = register
    copied_value = value
    return 0
end
local ok, err = xpcall(function()
    local copied_status = typst.viewer.preview_status({
        echo = false,
        notify = false,
    })
    assert(
        vim.g.typst_nvim_last_preview_url == failed_open_url,
        "preview status should keep the failed URL in g:typst_nvim_last_preview_url"
    )
    assert(
        copied_register == "+" and copied_value == failed_open_url,
        "preview status should try to copy the failed URL to the + register"
    )
    assert(
        table
            .concat(copied_status.lines, "\n")
            :find("copied to + register", 1, true),
        "preview status should report a successful URL copy"
    )
end, debug.traceback)
vim.fn.setreg = original_setreg
if not ok then
    error(err)
end
assert(
    fallback_preview.last_backend == "viewer",
    "native auto fallback should record viewer backend"
)

typst.reset({ force = true })

typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-browser-preflight-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        browser = {
            server = false,
            output_dir = test_cache_dir(
                "preview-native-browser-preflight-shell"
            ),
            commands = {
                { "typst-nvim-missing-browser-opener", "{url}" },
            },
        },
    },
})

vim.cmd.edit(main)
local preflight_project = live_project(typst.project.set_main(main))
done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before opener preflight")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before opener preflight"
)
local preflight = typst.viewer.preview({ mode = "document", notify = false })
assert(
    preflight and preflight.ok == false,
    "missing browser opener should return a structured failure"
)
assert(
    preflight.url and preflight.url:match("^file://"),
    "missing browser opener should still expose the preview URL"
)
assert(
    preflight.opener_candidates[1]:find("typst%-nvim%-missing%-browser%-opener"),
    "missing browser opener should report opener candidates"
)
assert(
    typst_test_preview(preflight_project).last_failed_url == preflight.url,
    "missing opener failure should be available in preview state"
)

typst.reset({ force = true })

typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-browser-declined-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        browser = {
            server = false,
            output_dir = test_cache_dir(
                "preview-native-browser-declined-shell"
            ),
            open = function()
                return {
                    ok = false,
                    reason = "declined",
                    message = "browser opener declined",
                }
            end,
        },
    },
})

vim.cmd.edit(main)
local declined_project = live_project(typst.project.set_main(main))
done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before declined browser open")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before declined browser open"
)
local declined_open = typst.viewer.preview({
    mode = "document",
    notify = false,
})
assert(
    declined_open and declined_open.ok == false,
    "structured browser open failure should fail native preview"
)
assert(
    declined_open.error == "browser opener declined",
    "structured browser open failure should preserve opener message"
)
assert(
    typst_test_preview(declined_project).active == false,
    "structured browser open failure should not leave preview active"
)
assert(
    typst_test_preview(declined_project).last_failed_url == declined_open.url,
    "structured browser open failure should preserve failed URL"
)

typst.reset({ force = true })

local original_executable = vim.fn.executable
local original_jobstart = vim.fn.jobstart
local original_ui_open = vim.ui.open
local app_jobs = {}
local ok, err = xpcall(function()
    vim.ui.open = function()
        error("selected browser app should bypass vim.ui.open")
    end
    vim.fn.executable = function(command)
        if command == "open" or command == "typst-nvim-selected-browser" then
            return 1
        end
        return original_executable(command)
    end
    vim.fn.jobstart = function(command, opts)
        app_jobs[#app_jobs + 1] = {
            command = command,
            opts = opts,
        }
        return 2468
    end

    typst.setup({
        root = root,
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-cycles.py"
        ),
        output_dir = test_cache_dir("preview-native-browser-app-output"),
        compile = {
            deps = false,
        },
        preview = {
            native = "browser",
            browser = {
                app = "typst-nvim-selected-browser",
                server = false,
                output_dir = test_cache_dir("preview-native-browser-app-shell"),
            },
        },
    })

    vim.cmd.edit(main)
    typst.project.set_main(main)
    done = false
    typst.compiler.compile({}, function(result)
        assert(result.code == 0, "compile failed before browser app selection")
        done = true
    end)
    assert(
        vim.wait(10000, function()
            return done
        end, 20),
        "Typst compile did not finish before browser app selection"
    )
    local app_preview = typst.viewer.preview({
        mode = "document",
        notify = false,
    })
    assert(
        app_preview and app_preview.ok == true,
        "selected browser app should open preview"
    )
    assert(app_jobs[1], "selected browser app should start an opener job")
    assert(
        table
            .concat(app_jobs[1].command, " ")
            :find("typst%-nvim%-selected%-browser"),
        "selected browser app should be present in opener command"
    )
    assert(
        app_jobs[1].opts and app_jobs[1].opts.detach == true,
        "selected browser app opener should be detached"
    )
end, debug.traceback)
vim.fn.executable = original_executable
vim.fn.jobstart = original_jobstart
vim.ui.open = original_ui_open
if not ok then
    error(err)
end

typst.reset({ force = true })

typst.providers.register("source_map", "file-shell-svg-source-map", {
    name = "file-shell-svg-source-map",
    capabilities = function()
        return {
            source_maps = true,
            forward = true,
            browser_click = true,
        }
    end,
    forward = function()
        return {
            ok = true,
            x = 1,
            y = 2,
            line = 1,
            column = 1,
        }
    end,
    browser_inverse = function(project_context)
        return {
            path = project_context.main,
            line = 1,
            column = 1,
        }
    end,
})

local svg_shell_opened = nil
local svg_export_provider = function(_project, opts, callback)
    vim.fn.writefile({
        '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"></svg>',
    }, opts.output_path)
    local result = {
        ok = true,
        path = opts.output_path,
        artifacts = {
            {
                path = opts.output_path,
                format = "svg",
            },
        },
    }
    if callback then
        callback(result)
    end
    return result
end
typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-browser-svg-compile-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        source_maps = {
            provider = "file-shell-svg-source-map",
        },
        browser = {
            server = false,
            output_dir = test_cache_dir("preview-native-browser-svg-shell"),
            export = {
                mode = "provider",
                provider = svg_export_provider,
                output_format = "svg",
            },
            open = function(url)
                svg_shell_opened = url
                return true
            end,
        },
    },
})

vim.cmd.edit(main)
local svg_shell_project = live_project(typst.project.set_main(main))
done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before SVG file-shell preview")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before SVG file-shell preview"
)
local svg_preview = typst.viewer.preview({ mode = "document" })
assert(svg_preview and svg_preview.ok == true)
assert(svg_shell_opened, "SVG file-shell preview should open")
local svg_shell_path = typst_test_preview(svg_shell_project).active_shell
local svg_state_path = svg_shell_path:gsub("%.html$", ".state.js")
local svg_state_text = table.concat(vim.fn.readfile(svg_state_path), "\n")
assert(
    svg_state_text:find('"output_format":"svg"', 1, true),
    "SVG file-shell state should expose SVG format"
)
assert(
    svg_state_text:find('"forward":true', 1, true),
    "SVG file-shell state should keep forward sync capability"
)
assert(
    svg_state_text:find('"browser_click":false', 1, true),
    "SVG file-shell state should disable browser click sync"
)
assert(
    svg_state_text:find(
        "Browser click source sync requires server mode",
        1,
        true
    ),
    "SVG file-shell state should explain server-mode click sync requirement"
)

typst.reset({ force = true })

local throttle_opened = nil
typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = test_cache_dir("preview-native-browser-throttle-output"),
    compile = {
        deps = false,
    },
    preview = {
        native = "browser",
        browser = {
            server = false,
            output_dir = test_cache_dir(
                "preview-native-browser-throttle-shell"
            ),
            reload_throttle_ms = 10000,
            open = function(url)
                throttle_opened = url
                return true
            end,
        },
    },
})

vim.cmd.edit(main)
local throttle_project = live_project(typst.project.set_main(main))
done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before reload throttle")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before reload throttle"
)
local throttle_preview = typst.viewer.preview({ mode = "document" })
assert(throttle_preview and throttle_preview.ok == true)
assert(throttle_opened, "throttle preview should open")
local first_refresh = preview_backend.refresh(throttle_project, {
    code = 0,
    generation = 1,
}, {
    source = "compile",
})
assert(
    first_refresh == true
        or (type(first_refresh) == "table" and first_refresh.ok),
    "first throttled preview refresh should run"
)
local second_refresh = preview_backend.refresh(throttle_project, {
    code = 0,
    generation = 2,
}, {
    source = "compile",
})
assert(
    second_refresh and second_refresh.throttled == true,
    "second immediate preview refresh should be throttled"
)
local manual_refresh = typst.viewer.preview_reload({
    notify = false,
})
assert(
    not (type(manual_refresh) == "table" and manual_refresh.throttled),
    "manual preview reload should bypass browser reload throttling"
)

vim.cmd("qa!")
