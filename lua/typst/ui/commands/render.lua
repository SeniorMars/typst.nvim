local command = require("typst.ui.commands.util")
local complete = require("typst.ui.commands.complete")

local M = {}

local create = command.create
local opts = command.opts

---Register Typst render user commands.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api

    create(
        "TypstPreviewFragment",
        function(args)
            api.render.fragment({
                line1 = args.line1,
                line2 = args.line2,
                range = args.range,
                format = args.args ~= "" and args.args or nil,
                open = not args.bang,
            })
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Render the selected Typst source",
                "?",
                complete.render_format
            ),
            {
                bang = true,
                range = true,
            }
        )
    )

    create(
        "TypstPreviewEquation",
        function(args)
            api.render.equation({
                expression = args.args ~= "" and args.args or nil,
                line1 = args.line1,
                line2 = args.line2,
                range = args.range,
                open = not args.bang,
            })
        end,
        vim.tbl_extend("force", opts("Render a Typst equation preview", "*"), {
            bang = true,
            range = true,
        })
    )

    create(
        "TypstPreviewImage",
        function(args)
            api.render.image({
                path = args.args ~= "" and args.args or nil,
                open = not args.bang,
            })
        end,
        vim.tbl_extend("force", opts("Preview an image path", "?", "file"), {
            bang = true,
        })
    )

    create(
        "TypstPreviewPage",
        function(args)
            local page = tonumber(args.args)
            api.render.page({
                page = page or 1,
                open = not args.bang,
            })
        end,
        vim.tbl_extend("force", opts("Render a page preview", "?"), {
            bang = true,
        })
    )

    create(
        "TypstRenderCacheClear",
        function(args)
            api.render.cache_clear({ force = args.bang })
        end,
        vim.tbl_extend(
            "force",
            opts("Clear the Typst rendered-preview cache"),
            { bang = true }
        )
    )
end

return M
