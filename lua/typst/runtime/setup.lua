local telemetry = require("typst.core.telemetry")

local M = {}

local did_setup_once = false
local did_configure = false
local runtime_api_installed_for = setmetatable({}, { __mode = "k" })
local package_prewarm_scheduled = false

local function install_runtime_api(api, notify)
    if runtime_api_installed_for[api] then
        return
    end

    local normalize_bufnr = require("typst.core.buffer").normalize_bufnr
    require("typst.api.reports").install(api, notify)
    require("typst.api.runtime").install(api, notify, normalize_bufnr)
    require("typst.api.workflows").install(api, notify, normalize_bufnr)
    require("typst.api.render").install(api, notify)
    require("typst.api.navigation").install(api, notify, normalize_bufnr)
    runtime_api_installed_for[api] = true
end

--- Install process-global runtime state once for a public API facade.
---@param api table Public API facade receiving runtime methods.
---@param notify fun(message:string, level?:integer)?
function M.setup_once(api, notify)
    require("typst.api.exports").install_globals()
    if did_setup_once then
        install_runtime_api(api, notify)
        return {
            ok = true,
            first_setup = false,
            setup_once = false,
        }
    end

    install_runtime_api(api, notify)
    require("typst.edit.mappings").register_plugs()
    require("typst.commands").register(api, { notify = notify })
    require("typst.core.lifecycle").register_autocmds()
    did_setup_once = true
    return {
        ok = true,
        first_setup = true,
        setup_once = true,
    }
end

local function maybe_prewarm_packages()
    if
        require("typst.config").get().completion.package_cache_prewarm
        and not package_prewarm_scheduled
    then
        local ok, package_completion =
            pcall(require, "typst.completion.packages")
        if ok and type(package_completion.prewarm) == "function" then
            local prewarm_ok, prewarm_err =
                pcall(package_completion.prewarm, { schedule = true })
            if prewarm_ok then
                package_prewarm_scheduled = true
            else
                require("typst.core.log").add(
                    "warn",
                    "package cache prewarm failed",
                    {
                        error = tostring(prewarm_err),
                    }
                )
            end
        end
    end
end

local function reconfigure_attached_buffers()
    local reapply =
        require("typst.project.attachments").reapply_attached_buffers()
    local follow_buffer = require("typst.preview.follow_buffer").setup()
    maybe_prewarm_packages()
    did_configure = true
    return {
        ok = true,
        reapply = reapply,
        follow_buffer = follow_buffer,
    }
end

local function configure_impl(opts)
    require("typst.config").setup(opts)
    return reconfigure_attached_buffers()
end

--- Apply user configuration and reconfigure attached buffers.
---@param opts? table User configuration.
---@return table result Configure summary.
function M.configure(opts)
    if not did_setup_once then
        return {
            ok = false,
            reason = "runtime_not_setup",
            message = "runtime.configure() requires setup_once() first",
        }
    end

    local result = configure_impl(opts)
    require("typst.core.events").emit_global("TypstEventConfigChanged", {
        did_setup = did_configure,
        first_setup = false,
        reconfigure = true,
        reapply = result.reapply,
    })
    return result
end

--- Initialize typst.nvim runtime services for the current session.
---@param api table Public API facade receiving runtime methods.
---@param notify fun(message:string, level?:integer)?
---@param opts? table User configuration.
---@return any result Telemetry-wrapped setup result.
function M.setup(api, notify, opts)
    local result = telemetry.time("setup", function()
        local events = require("typst.core.events")
        local first_setup = not did_configure
        events.emit_global("TypstEventInitPre", {
            did_setup = did_configure,
            first_setup = first_setup,
            reconfigure = not first_setup,
            setup_once = not did_setup_once,
        })

        -- Config is installed before first-time side effects so feature modules
        -- read the user configuration even when plugin/typst.lua auto-loads.
        require("typst.config").setup(opts)
        local setup_once_result = M.setup_once(api, notify)
        local configure_result = reconfigure_attached_buffers()
        if not first_setup then
            events.emit_global("TypstEventConfigChanged", {
                did_setup = true,
                first_setup = false,
                reconfigure = true,
                reapply = configure_result.reapply,
            })
        end
        require("typst.core.log").add("info", "setup complete")
        events.emit_global("TypstEventInitPost", {
            did_setup = did_configure,
            first_setup = first_setup,
            reconfigure = not first_setup,
            setup_once = setup_once_result.setup_once == true,
        })
    end)
    return result
end

--- Report whether setup has completed.
---@return boolean ready True after setup finishes.
function M.is_setup()
    return did_configure
end

local function reset_impl(opts)
    opts = opts or {}
    local reset_result = require("typst.runtime.resource_manager").reset(opts)
    did_setup_once = false
    did_configure = false
    package_prewarm_scheduled = false
    return reset_result
end

--- Reset runtime state for tests, reloads, or manual recovery.
---@param opts? {force?:boolean, keep_telemetry?:boolean} Reset controls.
---@return table|nil summary Reset summary. When active resources cannot be confirmed stopped and `force` is not true, projects may be retained.
function M.reset(opts)
    local summary = telemetry.time("reset", function()
        local result = reset_impl(opts)
        if not (opts and opts.keep_telemetry) then
            telemetry.reset()
        else
            telemetry.record("reset.kept_telemetry", 0)
        end
        return result
    end)
    return summary
end

return M
