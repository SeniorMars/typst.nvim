local insertions = require("typst.edit.api_insertions")
local navigation = require("typst.edit.api_navigation")
local transforms = require("typst.edit.api_transforms")

local M = {}

local default_notify = require("typst.core.notify").default

--- Create the public edit helper API table.
---@param opts? table API options, including optional notification callback.
---@return table api Edit API with navigation, transform, and insertion helpers.
function M.create(opts)
    opts = opts or {}
    local notify = opts.notify or default_notify
    local api = {}

    navigation.attach(api)
    transforms.attach(api, notify)
    insertions.attach(api)
    return api
end

return M
