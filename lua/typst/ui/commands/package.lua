local command = require("typst.ui.commands.util")
local complete = require("typst.ui.commands.complete")

local M = {}

local create = command.create
local opts = command.opts

---Register package discovery commands.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api

    create("TypstPackageInfo", function(args)
        return api.package.info({ query = args.args ~= "" and args.args or nil })
    end, opts(
        "Open Typst package resource information",
        "?",
        complete.package
    ))

    create("TypstPackageOpen", function(args)
        return api.package.open({ query = args.args ~= "" and args.args or nil })
    end, opts("Open the Typst Universe package page", "?", complete.package))

    create("TypstPackageReadme", function(args)
        return api.package.readme({
            query = args.args ~= "" and args.args or nil,
        })
    end, opts("Open the cached Typst package README", "?", complete.package))

    create(
        "TypstPackageSource",
        function(args)
            return api.package.source({
                query = args.args ~= "" and args.args or nil,
            })
        end,
        opts(
            "Open the cached Typst package source entrypoint",
            "?",
            complete.package
        )
    )

    create("TypstSymbolInfo", function(args)
        return api.symbol.info({ query = args.args ~= "" and args.args or nil })
    end, opts("Open Typst symbol information", "?", complete.symbol))

    create("TypstSymbolVariants", function(args)
        return api.symbol.variants({
            query = args.args ~= "" and args.args or nil,
        })
    end, opts("List Typst symbol variants", "?", complete.symbol))
end

return M
