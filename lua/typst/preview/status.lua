local native_preview_session = require("typst.preview.native.session")
local state = require("typst.preview.state_machine")

local M = {}

local function preview_cache()
    return require("typst.preview.cache")
end

---Return a controller-owned preview status snapshot.
---@param project table Project state.
---@param opts? table Status options.
---@return table status Preview status payload.
function M.snapshot(project, opts)
    opts = opts or {}
    local ok, status = pcall(state.status, project, opts)
    if not ok then
        return {
            ok = false,
            active = false,
            opening = false,
            stopping = false,
            status = "status_failed",
            reason = "preview_status_failed",
            message = tostring(status),
        }
    end
    if opts.cache ~= false then
        local cache_ok, cache_status = pcall(preview_cache().status, project)
        if cache_ok then
            status.cache = cache_status
        end
    end

    local native_ok, native =
        pcall(native_preview_session.project_state, project)
    native = native_ok and native or {}
    status.native = native
    if native and native.active then
        status.backend = status.backend or "native-browser"
        status.transport = status.transport or native.mode
        status.url = status.url or native.url
        status.output = status.output or native.output
        status.shell = status.shell or native.shell_path
    end

    return status
end

return M
