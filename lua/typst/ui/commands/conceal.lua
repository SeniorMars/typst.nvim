local command = require("typst.ui.commands.util")

local M = {}

local create = command.create
local opts = command.opts

---Register conceal toggle and maintenance commands.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api
    local notify = ctx.notify

    create("TypstConcealEnable", function()
        api.conceal.enable()
        notify("Typst conceal enabled")
    end, opts("Enable Typst conceal for the current buffer"))

    create("TypstConcealDisable", function()
        api.conceal.disable()
        notify("Typst conceal disabled")
    end, opts("Disable Typst conceal for the current buffer"))

    create("TypstConcealToggle", function()
        local enabled = api.conceal.toggle()
        notify(("Typst conceal %s"):format(enabled and "enabled" or "disabled"))
    end, opts("Toggle Typst conceal for the current buffer"))

    create("TypstConcealRefresh", function()
        api.conceal.refresh()
        notify("Typst conceal refreshed")
    end, opts("Refresh Typst conceal metadata and redraw"))

    create("TypstConcealInspect", function()
        api.conceal.inspect()
    end, opts("Inspect the Typst conceal rule under the cursor"))
end

return M
