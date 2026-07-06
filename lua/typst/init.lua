local M = {}

local api_exports = require("typst.api.exports")
local runtime_setup = require("typst.runtime.setup")

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

--- Return the versioned public API and event contract.
---@return table contract Public contract metadata for integrations and docs.
function M.contract()
    return require("typst.api.contract").snapshot()
end

--- Build a redacted bug-report artifact for support.
---@param opts? table Report controls such as `open`, `path`, and `redact`.
---@return table result Bug-report data plus JSON lines and optional buffer/path.
function M.report(opts)
    return require("typst.internal.debug").bug_report(opts)
end

--- Return machine-readable availability for stable Typst workflows.
---@param opts? table Reserved for future project-scoped capability checks.
---@return table capabilities Capability summary for tools, integrations, and workflows.
function M.capabilities(opts)
    return require("typst.api.capabilities").collect(opts)
end

local notify = require("typst.core.notify").default

api_exports.install(M, notify)

--- Initialize typst.nvim for the current Neovim session.
---@param opts? table User configuration merged by `typst.config.setup`.
---@return any result Telemetry-wrapped setup result.
function M.setup(opts)
    return runtime_setup.setup(M, notify, opts)
end

--- Report whether `setup()` has completed in this Neovim session.
---@return boolean ready True after setup finishes.
function M.is_setup()
    return runtime_setup.is_setup()
end

--- Reset typst.nvim state for tests, reloads, or manual recovery.
---@param opts? table Reset controls such as `force` and `keep_telemetry`.
---@return table|nil summary Lifecycle reset summary from project-resource cleanup.
function M.reset(opts)
    return runtime_setup.reset(opts)
end

return M
