local command = require("typst.ui.commands.util")
local unpack = require("typst.core.tables").unpack

local M = {}

local create = command.create
local opts = command.opts

local function pack_returns(...)
    return { n = select("#", ...), ... }
end

local function should_notify_success(values)
    local result = values[1]
    local err = values[2]
    if err ~= nil and (result == nil or result == false) then
        return false
    end
    if
        type(result) == "table"
        and (result.ok == false or result.pending == true)
    then
        return false
    end
    return true
end

local function notify_success(notify, message, ...)
    local values = pack_returns(...)
    if should_notify_success(values) then
        notify(message)
    end
    return unpack(values, 1, values.n)
end

local function notify_toggle(notify, ...)
    local values = pack_returns(...)
    if should_notify_success(values) then
        local result = values[1]
        notify(("Typst conceal %s"):format(result and "enabled" or "disabled"))
    end
    return unpack(values, 1, values.n)
end

local function call(method)
    return method()
end

local function call_and_notify(notify, message, method)
    return notify_success(notify, message, call(method))
end

local function call_toggle_and_notify(notify, method)
    return notify_toggle(notify, call(method))
end

---Register conceal toggle and maintenance commands.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api
    local notify = ctx.notify

    create("TypstConcealEnable", function()
        return call_and_notify(
            notify,
            "Typst conceal enabled",
            api.conceal.enable
        )
    end, opts("Enable Typst conceal for the current buffer"))

    create("TypstConcealDisable", function()
        return call_and_notify(
            notify,
            "Typst conceal disabled",
            api.conceal.disable
        )
    end, opts("Disable Typst conceal for the current buffer"))

    create("TypstConcealToggle", function()
        return call_toggle_and_notify(notify, api.conceal.toggle)
    end, opts("Toggle Typst conceal for the current buffer"))

    create("TypstConcealRefresh", function()
        return call_and_notify(
            notify,
            "Typst conceal refreshed",
            api.conceal.refresh
        )
    end, opts("Refresh Typst conceal metadata and redraw"))

    create("TypstConcealInspect", function()
        return api.conceal.inspect()
    end, opts("Inspect the Typst conceal rule under the cursor"))
end

return M
