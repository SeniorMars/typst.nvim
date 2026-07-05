local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local compiler_service = require("typst.project.services.compiler")
local config = require("typst.config")
local native = require("typst.preview.native")
local project_store = require("typst.project.store")
local typst = require("typst")

local function wait_for_handle(handle, label)
    assert(
        type(handle) == "table" and handle.pending == true,
        label .. " should return a pending handle"
    )
    local finished = vim.wait(10000, function()
        return handle.pending == false
    end, 20)
    if not finished then
        error(
            label
                .. " did not finish\n"
                .. table.concat(require("typst.core.log").lines(), "\n")
        )
    end
    return handle.result
end

local function finish_result(handle, label)
    assert(type(handle) == "table", label .. " should return a handle")
    if handle.result == nil then
        local finished = vim.wait(10000, function()
            return handle.pending == false
        end, 20)
        if not finished then
            error(
                label
                    .. " did not finish\n"
                    .. table.concat(require("typst.core.log").lines(), "\n")
            )
        end
    end
    return handle.result
end

typst.reset()

local viewer_opened = nil
---@type any
local provider_opts = nil
local provider_calls = 0
local export_provider = function(_project, opts, callback)
    provider_calls = provider_calls + 1
    provider_opts = opts
    vim.fn.writefile({ "<svg>preview</svg>" }, opts.output_path)
    local result = {
        ok = true,
        path = opts.output_path,
        artifacts = {
            {
                path = opts.output_path,
                format = opts.format or "pdf",
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
    output_dir = typst_test_cache_path("preview-export-compile-output"),
    viewer = {
        open = function(path)
            viewer_opened = path
            return true
        end,
    },
    preview = {
        native = "viewer",
        export = {
            mode = "provider",
            provider = export_provider,
            output_format = "svg",
        },
        browser = {
            output_dir = typst_test_cache_path("preview-provider-cache"),
        },
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project_snapshot = typst.project.set_main(main)
local project = assert(project_store.get(project_snapshot.key), "live project")
local compiler_output_before = (compiler_service.get(project) or {}).output

---@type any
local viewer_result = typst.viewer.preview({ mode = "document" })
assert(
    viewer_result == viewer_opened,
    "native viewer preview should open the provider export path"
)
assert(provider_calls == 1, "preview export provider should be called")
assert(
    provider_opts.update_compiler_output == false,
    "preview export should not replace compiler output"
)
assert(
    provider_opts.preview == true,
    "preview provider should receive preview tag"
)
assert(
    provider_opts.producer == "preview",
    "preview provider should receive preview producer"
)
assert(
    provider_opts.preview_target == "viewer",
    "preview provider should receive preview target"
)
assert(
    (compiler_service.get(project) or {}).output == compiler_output_before,
    "preview provider export should preserve compiler output state"
)
assert(
    typst_test_preview(project).last_export.mode == "provider",
    "preview state should record provider export mode"
)
assert(
    typst_test_preview(project).last_export.output_format == "svg",
    "preview state should record provider export format"
)
local preview_artifacts = typst.artifact.list({ producer = "preview" })
assert(
    #preview_artifacts == 1,
    "preview provider export should be registered as a preview artifact"
)
assert(
    preview_artifacts[1].path == viewer_result,
    "preview artifact registry should point at the provider output"
)
assert(
    preview_artifacts[1].preview_export.mode == "provider",
    "preview artifact should record preview export mode"
)
assert(
    preview_artifacts[1].preview_export.target == "viewer",
    "preview artifact should record preview export target"
)
local preview_clean = typst.viewer.clean({ all = true, force = true })
assert(
    preview_clean.preview_artifacts_deleted == 1,
    "TypstClean! should clean preview-owned exports separately"
)
assert(
    vim.fn.filereadable(viewer_result) == 0,
    "TypstClean! should remove preview-owned export output"
)

typst.reset({ force = true })
local opened_url = nil
typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-watch-cycles.py"
    ),
    output_dir = typst_test_cache_path("preview-profile-compile-output"),
    compile = {
        deps = false,
    },
    exports = {
        profiles = {
            browser_preview = {
                format = "svg",
                output_dir = typst_test_cache_path(
                    "preview-profile-export-output"
                ),
                output_name = "browser-preview",
            },
        },
    },
    preview = {
        native = "browser",
        browser = {
            server = false,
            output_dir = typst_test_cache_path("preview-profile-shell"),
            open = function(url)
                opened_url = url
                return true
            end,
            export = {
                mode = "profile",
                profile = "browser_preview",
            },
        },
    },
})
vim.cmd.edit(main)
project_snapshot = typst.project.set_main(main)
project = assert(project_store.get(project_snapshot.key), "live project")
compiler_output_before = (compiler_service.get(project) or {}).output

local browser_result =
    wait_for_handle(typst.viewer.preview({ mode = "document" }), "preview")
assert(browser_result and browser_result.ok == true, "browser preview failed")
assert(opened_url == browser_result.url, "browser preview should open URL")
assert(
    browser_result.output:match("browser%-preview%.svg$"),
    "profile preview should use the export profile artifact"
)
assert(
    (compiler_service.get(project) or {}).output == compiler_output_before,
    "preview profile export should preserve compiler output state"
)

local preview_state = typst_test_preview(project)
assert(
    preview_state.active_transport == "file-shell",
    "preview state should record file-shell transport"
)
assert(
    preview_state.active_output == browser_result.output,
    "preview state should record active preview output"
)
assert(
    preview_state.active_export.mode == "profile",
    "preview state should record active export mode"
)
assert(
    preview_state.active_export.profile == "browser_preview",
    "preview state should record active export profile"
)

local capabilities = typst.viewer.preview_capabilities()
assert(
    capabilities.backend == "native-browser",
    "native browser should report its backend"
)
assert(
    capabilities.source_maps == true,
    "native browser should advertise typst-query source maps for SVG preview output"
)
assert(
    capabilities.source_sync_provider == "typst-query",
    "native browser should report the default SVG source-sync provider"
)

local refreshed = wait_for_handle(
    require("typst.integrations.typst_preview").refresh(project, {
        code = 0,
        generation = 99,
    }),
    "preview refresh"
)
assert(
    refreshed == true,
    "native browser refresh should complete after preview profile export"
)
assert(
    typst_test_preview(project).active_output:match("browser%-preview%.svg$"),
    "refresh should keep the preview profile artifact active"
)

local echoed = {}
local old_echo = vim.api.nvim_echo
rawset(vim.api, "nvim_echo", function(chunks)
    for _, chunk in ipairs(chunks) do
        echoed[#echoed + 1] = chunk[1]
    end
end)
typst.ui.info()
vim.api.nvim_echo = old_echo
local info_text = table.concat(echoed, "\n")
assert(
    info_text:find("preview transport:%s+file%-shell"),
    "TypstInfo should show native preview transport"
)
assert(info_text:find("preview url:"), "TypstInfo should show preview URL")
assert(info_text:find("preview shell:"), "TypstInfo should show file shell")
assert(info_text:find("preview output:"), "TypstInfo should show output")
assert(
    info_text:find("preview export:%s+target=browser mode=profile"),
    "TypstInfo should show preview export mode"
)
assert(
    info_text:find("artifacts:%s+document=0 preview=1 other=0"),
    "TypstInfo should distinguish preview artifacts"
)
assert(
    info_text:find("preview exports:%s+total=1"),
    "TypstInfo should report preview export artifact totals"
)
assert(
    info_text:find("target:browser=1"),
    "TypstInfo should report preview export targets"
)

local messages = {}
local old_health = vim.health
vim.health = {
    start = function(message)
        messages[#messages + 1] = { level = "start", message = message }
    end,
    ok = function(message)
        messages[#messages + 1] = { level = "ok", message = message }
    end,
    warn = function(message)
        messages[#messages + 1] = { level = "warn", message = message }
    end,
    error = function(message)
        messages[#messages + 1] = { level = "error", message = message }
    end,
}
require("typst.health").check()
vim.health = old_health

local saw_preview_health = false
for _, item in ipairs(messages) do
    if
        item.level == "ok"
        and item.message:find("preview_backend=native-browser", 1, true)
        and item.message:find("preview_transport=file-shell", 1, true)
        and item.message:find("preview_url=", 1, true)
        and item.message:find("preview_shell=", 1, true)
        and item.message:find("preview_output=", 1, true)
        and item.message:find(
            "preview_export=target:browser,mode:profile",
            1,
            true
        )
        and item.message:find("preview_exports=total:1", 1, true)
        and item.message:find("target:browser:1", 1, true)
    then
        saw_preview_health = true
    end
end

assert(saw_preview_health, "health should show native preview browser state")

typst.reset({ force = true })
local race_opened_url = nil
local pending_exports = {}
local race_calls = 0
local race_refresh_callbacks = 0
local race_provider = function(_project, opts, callback)
    race_calls = race_calls + 1
    vim.fn.writefile({ ("race %d"):format(race_calls) }, opts.output_path)
    local result = {
        ok = true,
        path = opts.output_path,
        artifacts = {
            {
                path = opts.output_path,
                format = opts.format or "pdf",
            },
        },
    }
    if race_calls == 1 then
        callback(result)
        return result
    end

    local handle = {
        pending = true,
    }
    function handle:on_finish(on_finish)
        self._on_finish = on_finish
        return self
    end
    function handle:finish()
        self.pending = false
        callback(result)
        if self._on_finish then
            self._on_finish(result)
        end
        return result
    end
    function handle:cancel()
        self.pending = false
        return true, { ok = false, reason = "cancelled", stopped = true }
    end
    pending_exports[#pending_exports + 1] = handle
    return handle
end

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-race-compile-output"),
    preview = {
        native = "browser",
        refresh = function()
            race_refresh_callbacks = race_refresh_callbacks + 1
            return true
        end,
        browser = {
            server = false,
            output_dir = typst_test_cache_path("preview-race-shell"),
            open = function(url)
                race_opened_url = url
                return true
            end,
            export = {
                mode = "provider",
                provider = race_provider,
                output_format = "svg",
                output_name = "race-open",
            },
        },
    },
})
vim.cmd.edit(main)
project_snapshot = typst.project.set_main(main)
project = assert(project_store.get(project_snapshot.key), "live project")

local race_open = typst.viewer.preview({ mode = "document" })
assert(race_open and race_open.ok == true, "race preview should open")
assert(race_opened_url == race_open.url, "race preview should open URL")

local manual_reload = typst.viewer.preview_reload({
    output_name = "race-manual",
    output_format = "svg",
})
assert(
    manual_reload and manual_reload.pending == true,
    "manual native browser reload should expose pending preview export"
)
assert(
    race_refresh_callbacks == 1,
    "manual native browser reload should still notify preview refresh callback"
)
assert(#pending_exports == 1, "manual reload should hold one pending export")
pending_exports[1]:finish()
local manual_result = finish_result(manual_reload, "manual preview reload")
assert(
    manual_result
        and manual_result.native == true
        and manual_result.callback == true,
    "manual native browser reload should finish with native and callback results"
)
assert(
    typst_test_preview(project).active_output:match("race%-manual%.svg$"),
    "manual native browser reload should honor one-shot output override"
)

config.unsafe_get().preview.browser.export.output_name = "race-old"
local old_refresh = native.refresh(project, { code = 0, cycle = 1 })
assert(
    old_refresh and old_refresh.pending == true,
    "old preview refresh should be pending"
)
config.unsafe_get().preview.browser.export.output_name = "race-new"
local new_refresh = native.refresh(project, { code = 0, cycle = 2 })
assert(
    new_refresh and new_refresh.pending == true,
    "new preview refresh should be pending"
)
assert(#pending_exports == 3, "race test should hold three pending exports")

pending_exports[3]:finish()
local new_result = finish_result(new_refresh, "new preview refresh")
assert(new_result == true, "new preview refresh should win")
assert(
    typst_test_preview(project).last_result.cycle == 2,
    "new refresh should update preview state"
)
assert(
    typst_test_preview(project).active_output:match("race%-new%.svg$"),
    "new refresh output should become active"
)

pending_exports[2]:finish()
local old_result = finish_result(old_refresh, "old preview refresh")
assert(
    old_result and old_result.stale == true,
    "old preview refresh should be ignored as stale"
)
assert(
    typst_test_preview(project).last_result.cycle == 2,
    "stale refresh should not overwrite newer preview state"
)
assert(
    typst_test_preview(project).active_output:match("race%-new%.svg$"),
    "stale refresh should not replace the active output"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-missing-output"),
    preview = {
        native = "viewer",
        export = {
            mode = "compile",
        },
    },
})
vim.cmd.edit(main)
typst.project.set_main(main)
local missing_output = typst.viewer.preview({ notify = false })
assert(
    type(missing_output) == "table"
        and missing_output.ok == false
        and missing_output.reason == "missing_compiler_output",
    "compile-mode preview without output should return structured failure"
)
assert(
    missing_output.message:find(":TypstCompile", 1, true)
        and missing_output.message:find("preview.export.mode", 1, true),
    "missing output message should include next steps"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-invalid-native"),
    preview = {
        native = "viewer",
    },
})
vim.cmd.edit(main)
typst.project.set_main(main)
local invalid_native = typst.viewer.preview({
    notify = false,
    native = "invalid-target",
})
assert(
    type(invalid_native) == "table"
        and invalid_native.ok == false
        and invalid_native.reason == "invalid_preview_native",
    "invalid native preview config should return structured failure"
)

vim.cmd("qa!")
