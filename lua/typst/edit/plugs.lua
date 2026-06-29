local plug_groups = require("typst.edit.plug_groups")

local M = {}

local plugs_registered = false

M.motion_modes = plug_groups.motion_modes

function M.register()
    if plugs_registered then
        return
    end

    plug_groups.register()
    plugs_registered = true
end

return M
