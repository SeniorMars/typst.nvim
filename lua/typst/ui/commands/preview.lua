local command = require("typst.ui.commands.util")
local complete = require("typst.ui.commands.complete")

local M = {}

local create = command.create
local opts = command.opts
local own_command_definition =
    "Delegate to the configured Typst preview backend"
local own_stop_command_definition = "Stop the configured Typst preview backend"
local own_toggle_command_definition =
    "Toggle the configured Typst preview backend"
local own_inverse_command_definition =
    "Jump from a Typst preview source map to source"
local own_browser_command_definition = "Open Typst preview in native browser"
local own_reload_command_definition = "Reload the active Typst preview"
local own_status_command_definition = "Show Typst preview status"
local own_clean_command_definition = "Clean preview-owned Typst artifacts"

local function preview_opts(args)
    local parsed = {}
    for _, token in ipairs(args.fargs or {}) do
        if token == "restart" then
            parsed.restart = true
        else
            local key, value = token:match("^([^=]+)=(.*)$")
            if key and value then
                if key == "mode" then
                    parsed.mode = value
                elseif key == "native" then
                    parsed.native = value
                elseif key == "profile" then
                    parsed.profile = value
                elseif key == "format" then
                    parsed.output_format = value
                elseif key == "export" then
                    parsed.export_mode = value
                elseif key == "output" or key == "name" then
                    parsed.output_name = value
                elseif key == "dir" or key == "output_dir" then
                    parsed.output_dir = value
                end
            elseif token ~= "" then
                parsed.mode = token
            end
        end
    end
    return parsed
end

---Register preview entry points.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api

    create(
        "TypstPreview",
        function(args)
            return api.viewer.preview(preview_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(own_command_definition, "*", complete.preview_args),
            {
                force = false,
            }
        )
    )

    create(
        "TypstPreviewOpenBrowser",
        function(args)
            local parsed = preview_opts(args)
            parsed.native = "browser"
            parsed.restart = args.bang or parsed.restart
            return api.viewer.preview_open_browser(parsed)
        end,
        vim.tbl_extend(
            "force",
            opts(own_browser_command_definition, "*", complete.preview_args),
            {
                bang = true,
                force = false,
            }
        )
    )

    create(
        "TypstPreviewReload",
        function(args)
            return api.viewer.preview_reload(preview_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(own_reload_command_definition, "*", complete.preview_args),
            {
                force = false,
            }
        )
    )

    create(
        "TypstPreviewStatus",
        function(args)
            if args.bang then
                local result = api.viewer.preview_status({
                    echo = false,
                    notify = false,
                })
                if not (result and result.ok) then
                    return result
                end
                require("typst.ui.reports").open_scratch_buffer(
                    "typst.nvim preview status",
                    "typstpreviewstatus",
                    result.lines or {}
                )
                return result
            else
                return api.viewer.preview_status()
            end
        end,
        vim.tbl_extend("force", opts(own_status_command_definition), {
            bang = true,
            force = false,
        })
    )

    create(
        "TypstCleanPreview",
        function(args)
            return api.viewer.clean_preview({
                force = args.bang,
                format = args.args ~= "" and args.args or nil,
            })
        end,
        vim.tbl_extend(
            "force",
            opts(own_clean_command_definition, "?", complete.preview_format),
            {
                bang = true,
                force = false,
            }
        )
    )

    create(
        "TypstPreviewStop",
        function()
            return api.viewer.preview_stop()
        end,
        vim.tbl_extend("force", opts(own_stop_command_definition), {
            force = false,
        })
    )

    create(
        "TypstPreviewToggle",
        function(args)
            return api.viewer.preview_toggle(preview_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(own_toggle_command_definition, "*", complete.preview_args),
            {
                force = false,
            }
        )
    )

    create(
        "TypstPreviewInverse",
        function(args)
            return api.viewer.preview_inverse({
                path = args.fargs[1],
                line = args.fargs[2],
                column = args.fargs[3],
            })
        end,
        vim.tbl_extend(
            "force",
            opts(own_inverse_command_definition, "*", "file"),
            {
                force = false,
            }
        )
    )
end

return M
