local M = {}

local modules = {
    require("typst.core.path"),
    require("typst.core.owned_path"),
    require("typst.core.files"),
    require("typst.core.tables"),
    require("typst.core.text"),
    require("typst.core.command"),
    require("typst.core.buffer"),
    require("typst.core.xdg"),
    require("typst.core.project_id"),
}

for _, module in ipairs(modules) do
    for name, value in pairs(module) do
        M[name] = value
    end
end

return M
