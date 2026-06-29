local M = {}

local group_modules = {
    "typst.ui.commands.project",
    "typst.ui.commands.compiler",
    "typst.ui.commands.navigation",
    "typst.ui.commands.bibliography",
    "typst.ui.commands.conceal",
    "typst.ui.commands.package",
    "typst.ui.commands.edit",
    "typst.ui.commands.preview",
    "typst.ui.commands.workflows",
    "typst.ui.commands.render",
    "typst.ui.commands.debug",
}

local default_notify = require("typst.core.notify").default

--- Register all user-facing `:Typst*` commands.
---@param typst_api table Public API facade passed by `require("typst")`.
---@param opts? table Command registration options, including `notify` and test API overrides.
function M.register(typst_api, opts)
    opts = opts or {}
    local notify = opts.notify or default_notify
    local ctx = {
        api = opts.api or require("typst.internal.commands_api").create({
            notify = notify,
        }),
        notify = notify,
    }

    -- Keep the command surface explicit. Several tests and downstream configs
    -- treat these :Typst* commands as the user-facing contract.
    for _, module_name in ipairs(group_modules) do
        require(module_name).register(ctx)
    end
end

return M
