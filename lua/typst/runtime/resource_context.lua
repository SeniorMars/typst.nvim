local M = {}

local epoch = 0
local resetting = false
local started_at = nil

local function hrtime()
    local uv = vim.uv or vim.loop
    return uv and uv.hrtime() or 0
end

---Begin a resource-manager reset epoch.
---@param opts? table Reset options recorded for diagnostics.
---@return table ctx Reset context.
function M.begin_reset(opts)
    epoch = epoch + 1
    resetting = true
    started_at = hrtime()
    return {
        epoch = epoch,
        resetting = true,
        started_at = started_at,
        opts = opts or {},
    }
end

---Finish the active reset epoch.
---@return table state Current reset context state.
function M.end_reset()
    resetting = false
    return M.state()
end

---Return the current resource-manager epoch.
---@return integer epoch Current epoch.
function M.epoch()
    return epoch
end

---Return whether a resource-manager reset is in progress.
---@return boolean resetting True during reset execution.
function M.in_reset()
    return resetting
end

---Return current reset context state.
---@return table state Reset state snapshot.
function M.state()
    return {
        epoch = epoch,
        resetting = resetting,
        started_at = started_at,
    }
end

---Build a coarse reset/project validity token.
---@param project? table Project associated with the token.
---@param kind? string Token purpose.
---@return table token Reset/project validity token.
function M.token(project, kind)
    return {
        epoch = epoch,
        kind = kind,
        project_key = type(project) == "table" and project.key or nil,
        instance_id = type(project) == "table" and project.instance_id or nil,
    }
end

---Check whether a token still matches the current reset/project epoch.
---@param token table? Token returned by `token`.
---@return boolean valid True when still valid.
---@return string? reason Invalid reason.
function M.valid_token(token)
    if type(token) ~= "table" then
        return false, "invalid_token"
    end
    if token.epoch ~= epoch then
        return false, "reset"
    end
    if token.project_key then
        local project = require("typst.project.store").get(token.project_key)
        if not project or project.instance_id ~= token.instance_id then
            return false, "project_changed"
        end
    end
    return true, nil
end

return M
