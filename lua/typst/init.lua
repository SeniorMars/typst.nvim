local M = {}

local api_exports = require("typst.api.exports")
local telemetry = require("typst.core.telemetry")

local did_setup = false
local runtime_api_installed = false
local API_VERSION = 1

M.API_VERSION = API_VERSION

--- Return the current public API version.
---@return number version Current public API version for this plugin.
function M.api_version()
    return API_VERSION
end

--- Return public API version metadata.
---@return table version Plugin API version metadata.
function M.version()
    return {
        api = API_VERSION,
        api_version = API_VERSION,
    }
end

local notify = require("typst.core.notify").default

api_exports.install(M, notify)

local function reset_loaded(module_name, ...)
    local module = package.loaded[module_name]
    if type(module) == "table" and type(module.reset) == "function" then
        module.reset(...)
    end
end

local function install_runtime_api()
    if runtime_api_installed then
        return
    end

    local normalize_bufnr = require("typst.core.buffer").normalize_bufnr
    require("typst.api.reports").install(M, notify)
    require("typst.api.runtime").install(M, notify, normalize_bufnr)
    require("typst.api.workflows").install(M, notify, normalize_bufnr)
    require("typst.api.render").install(M, notify)
    require("typst.api.navigation").install(M, notify, normalize_bufnr)
    runtime_api_installed = true
end

--- Initialize typst.nvim for the current Neovim session.
---@param opts? table User configuration merged by `typst.config.setup`.
---@return any result Telemetry-wrapped setup result.
function M.setup(opts)
    local result = telemetry.time("setup", function()
        local events = require("typst.core.events")
        events.emit_global("TypstEventInitPre", {
            did_setup = did_setup,
        })
        -- Order matters: config must be visible before feature modules read
        -- defaults, and commands should be registered only after the public API
        -- facade above has been installed.
        require("typst.config").setup(opts)
        install_runtime_api()
        require("typst.edit.mappings").register_plugs()
        require("typst.commands").register(M, { notify = notify })
        require("typst.core.lifecycle").register_autocmds()
        require("typst.preview.follow_buffer").setup()
        require("typst.project.lifecycle").reapply_attached_buffers()
        if require("typst.config").get().completion.package_cache_prewarm then
            local ok, package_completion =
                pcall(require, "typst.completion.packages")
            if ok then
                package_completion.prewarm({ schedule = true })
            end
        end
        did_setup = true
        require("typst.core.log").add("info", "setup complete")
        events.emit_global("TypstEventInitPost", {
            did_setup = did_setup,
        })
    end)
    return result
end

--- Report whether `setup()` has completed in this Neovim session.
---@return boolean ready True after setup finishes.
function M.is_setup()
    return did_setup
end

--- Reset project resources and plugin caches.
---@param opts? table Internal reset options consumed by lifecycle cleanup.
---@return table|nil summary Lifecycle reset summary when active resources were stopped or retained.
local function reset_impl(opts)
    opts = opts or {}
    local log = require("typst.core.log")
    local reset_result =
        require("typst.core.lifecycle").reset_project_resources(opts)
    local retain_projects = reset_result
        and reset_result.ok == false
        and opts.force ~= true
    require("typst.core.ftplugin_state").reset()
    require("typst.core.buffer").reset()
    if retain_projects then
        log.add(
            "warn",
            "retaining projects after reset because active resources remain",
            reset_result
        )
    else
        require("typst.project").reset()
    end

    -- Optional subsystems are lazy-loaded by API wrappers and buffer features.
    -- Reset only modules that were actually loaded so reset/reconfigure cycles
    -- do not defeat modular loading by requiring every feature implementation.
    reset_loaded("typst.conceal")
    reset_loaded("typst.edit.match_highlight")
    reset_loaded("typst.edit.indent")
    reset_loaded("typst.bibliography.edit")
    reset_loaded("typst.formatting")
    reset_loaded("typst.completion")
    reset_loaded("typst.completion.packages")
    if not retain_projects then
        require("typst.core.path_leases").reset()
        reset_loaded("typst.workflows.artifacts")
    end
    reset_loaded("typst.package")
    reset_loaded("typst.metadata.symbol")
    reset_loaded("typst.metadata")
    reset_loaded("typst.preview.follow_buffer")
    reset_loaded("typst.preview.source_maps.typst_query")
    require("typst.core.state").reset_cache()
    if not retain_projects then
        log.clear()
    end
    did_setup = false
    return reset_result
end

--- Reset typst.nvim state for tests, reloads, or manual recovery.
---@param opts? table Reset controls such as `force` and `keep_telemetry`.
---@return table|nil summary Lifecycle reset summary from project-resource cleanup.
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
