local command = require("typst.ui.commands.util")
local complete = require("typst.ui.commands.complete")

local M = {}

local create = command.create
local opts = command.opts

---Register Typst navigation user commands.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api

    create("TypstToc", function()
        return api.navigation.toc()
    end, opts("Open the current project's Typst outline"))

    create("TypstTocOpen", function()
        return api.navigation.toc_open()
    end, opts("Open the current project's Typst outline"))

    create("TypstTocRefresh", function()
        return api.navigation.toc_refresh()
    end, opts("Refresh the current project's Typst outline"))

    create("TypstTocToggle", function()
        return api.navigation.toc_toggle()
    end, opts("Toggle the current project's Typst outline window"))

    create("TypstLabels", function()
        return api.navigation.labels()
    end, opts("List labels in the current Typst project"))

    create("TypstCitations", function()
        return api.navigation.citations()
    end, opts("List bibliography keys in the current Typst project"))

    create("TypstSymbols", function()
        return api.navigation.symbols()
    end, opts("List local Typst symbols in the current project"))

    create("TypstPick", function(args)
        return api.picker.open({ kind = args.args ~= "" and args.args or nil })
    end, opts("Pick Typst project index items", "?", complete.picker))

    create("TypstFollow", function()
        return api.navigation.follow()
    end, opts("Follow the Typst target under the cursor"))

    create("TypstContextMenu", function()
        return api.context.open()
    end, opts("Open Typst context actions for the item under the cursor"))
end

return M
