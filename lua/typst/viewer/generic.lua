local events = require("typst.core.events")
local generic_helpers = require("typst.viewer.generic_helpers")
local log = require("typst.core.log")
local open_helper = require("typst.core.open")
local provider_adapter = require("typst.integrations.provider_adapter")
local providers = require("typst.integrations.providers")
local compiler_service = require("typst.project.services.compiler")
local viewer_service = require("typst.project.services.viewer")
local source_sync = require("typst.viewer.source_sync")

-- Generic PDF viewer backend.
--
-- This layer records the last viewer that successfully opened a project output
-- and treats callback viewers as synchronous. A callback returning false is a
-- deliberate decline, distinct from an error, so custom integrations can hand
-- off to another viewer without producing user-facing failures.
local M = {}

local effective_viewer = generic_helpers.effective_viewer
local backend_name = generic_helpers.backend_name
local record_last_viewer = generic_helpers.record_last_viewer
local executable_open = generic_helpers.executable_open

--- Open the current compiler output with the configured generic viewer backend.
---@param project table Project state whose compiler output should be opened.
---@param opts? table Open options; `path` overrides compiler output for preview-owned artifacts.
---@return string|false path Opened output path, or false when the viewer declined.
function M.open(project, opts)
    opts = opts or {}
    -- Use compiler state rather than deriving the PDF from the current buffer:
    -- the buffer may be an included file while the rendered output belongs to
    -- the Typst main file or an active compile profile.
    local path = opts.path or (compiler_service.get(project) or {}).output
    if not path or vim.fn.filereadable(path) ~= 1 then
        error(("typst.nvim: output does not exist: %s"):format(path or "<nil>"))
    end

    local viewer = effective_viewer()
    local opener = viewer.open
    if type(opener) == "function" then
        local result = provider_adapter.invoke(
            {
                name = viewer.provider,
                open = opener,
            },
            "open",
            providers.project_context(project),
            nil,
            {
                kind = "viewer-open",
                provider_name = viewer.provider,
                async = false,
                allow_nil_result = true,
                args = { path, providers.project_context(project) },
                callback_position = 3,
                normalize = function(raw)
                    return raw == nil and true or raw
                end,
            }
        )
        if type(result) == "table" and result.ok == false then
            log.add("warn", "viewer open callback failed", {
                provider = viewer.provider,
                main = project.main,
                output = path,
                error = result.error or result.message,
            })
            error(
                ("typst.nvim: viewer open callback failed: %s"):format(
                    result.message or result.error or "unknown error"
                )
            )
        end
        if result == false then
            log.add("debug", "viewer open callback declined", {
                provider = viewer.provider,
                main = project.main,
                output = path,
            })
            return false
        end
        record_last_viewer(
            project,
            viewer,
            backend_name(viewer, "callback"),
            nil,
            nil
        )
    elseif not executable_open(project, path, viewer) then
        if vim.ui and vim.ui.open then
            local object, err = open_helper.ui_open(path)
            if not object then
                error(("typst.nvim: vim.ui.open failed: %s"):format(err))
            end
            record_last_viewer(project, viewer, "vim.ui.open", nil, nil)
        else
            error(
                "typst.nvim: vim.ui.open is unavailable; configure viewer.open"
            )
        end
    end

    local viewer_state = viewer_service.get(project) or {}
    log.add("info", "view opened", {
        output = path,
        backend = viewer_state.backend,
        provider = viewer_state.provider,
        command = viewer_state.command,
        cwd = viewer_state.cwd,
    })
    events.emit("TypstViewOpened", project, {
        viewer_provider = viewer_state.provider,
        viewer_backend = viewer_state.backend,
        viewer_command = viewer_state.command,
        viewer_cwd = viewer_state.cwd,
    })
    return path
end

--- Return the compiler output path used by the generic viewer backend.
---@param project table Project state whose compiler service is queried.
---@return string? path Current compiler output path.
function M.output(project)
    return (compiler_service.get(project) or {}).output
end

--- Notify a configured viewer reload callback after a compile/watch result.
---@param project table Project state whose viewer should reload.
---@param result? table Compile/watch result that triggered the reload.
---@param opts? table Reload options.
---@return table|boolean|nil result Viewer callback result.
function M.reload(project, result, opts)
    opts = opts or {}
    local viewer = effective_viewer()
    if type(viewer.reload) ~= "function" then
        return nil
    end

    local reload_result = provider_adapter.invoke(
        {
            name = viewer.provider,
            reload = viewer.reload,
        },
        "reload",
        providers.project_context(project),
        opts,
        {
            kind = "viewer-reload",
            provider_name = viewer.provider,
            async = false,
            allow_nil_result = true,
            args = { providers.project_context(project), result, opts },
            callback_position = 4,
            normalize = function(raw)
                return raw == nil and true or raw
            end,
        }
    )
    if type(reload_result) == "table" and reload_result.ok == false then
        log.add("warn", "viewer reload callback failed", {
            provider = viewer.provider,
            main = project.main,
            error = reload_result.error or reload_result.message,
        })
        return reload_result
    end

    if reload_result ~= false then
        record_last_viewer(
            project,
            viewer,
            backend_name(viewer, "reload-callback"),
            nil,
            nil
        )
        log.add("debug", "viewer reload callback notified", {
            provider = viewer.provider,
            main = project.main,
            cycle = result and result.cycle,
            code = result and result.code,
        })
    end

    return reload_result
end

--- Run viewer forward search for a project.
---@param project table Project state whose output/source context is used.
---@param opts? table Forward-search options.
---@return table|boolean|string|nil result Source-sync backend result.
function M.forward(project, opts)
    return source_sync.forward(project, opts)
end

--- Run viewer inverse search for a project.
---@param project table Project state whose source context is used.
---@param opts? table Inverse-search options.
---@return table|boolean|nil result Source-sync backend result.
function M.inverse(project, opts)
    return source_sync.inverse(project, opts)
end

--- Return source-sync capabilities for the effective generic viewer.
---@return table capabilities Capability snapshot.
function M.capabilities()
    return source_sync.capabilities()
end

--- Return the effective viewer configuration after provider defaults are merged.
---@return table viewer Effective viewer configuration.
function M.effective()
    return effective_viewer()
end

return M
