local runtime = require("typst.preview.backends.delegated_runtime")
local results = require("typst.preview.results")

local M = {}

M.own_command_definition = runtime.own_command_definition
M.own_stop_command_definition = runtime.own_stop_command_definition
M.own_toggle_command_definition = runtime.own_toggle_command_definition
M.own_inverse_command_definition = runtime.own_inverse_command_definition

M.available = runtime.available
M.command_available = runtime.command_available
M.run_from_main = runtime.run_from_main
M.run_at_position = runtime.run_at_position

local function command_with_mode(base, mode)
    if mode and mode ~= "" then
        return base .. " " .. mode
    end
    return base
end

---Create a backend wrapper for typst-preview.nvim delegation.
---@return table backend Delegated preview backend.
function M.create()
    return {
        name = "typst-preview.nvim",
        kind = "delegated",

        open = function(_, project, opts)
            if not runtime.command_available("TypstPreview") then
                return results.failed(
                    "preview_backend_unavailable",
                    "TypstPreview command is unavailable",
                    { backend = "typst-preview.nvim" }
                )
            end
            local command =
                command_with_mode("TypstPreview", opts and opts.mode)
            local cwd = runtime.run_from_main(project, command)
            return {
                ok = true,
                opened = true,
                backend = "typst-preview.nvim",
                command = { command },
                cwd = cwd,
                mode = opts and opts.mode,
            }
        end,

        stop = function(_, project)
            if not runtime.command_available("TypstPreviewStop") then
                return results.failed(
                    "unsupported",
                    "TypstPreviewStop command is unavailable",
                    { backend = "typst-preview.nvim" }
                )
            end
            local command = "TypstPreviewStop"
            local cwd = runtime.run_from_main(project, command)
            return {
                ok = true,
                stopped = true,
                backend = "typst-preview.nvim",
                command = { command },
                cwd = cwd,
            }
        end,

        toggle = function(_, project, opts)
            if not runtime.command_available("TypstPreviewToggle") then
                return results.failed(
                    "unsupported",
                    "TypstPreviewToggle command is unavailable",
                    { backend = "typst-preview.nvim" }
                )
            end
            local command = "TypstPreviewToggle"
            local cwd = runtime.run_from_main(project, command)
            return {
                ok = true,
                backend = "typst-preview.nvim",
                command = { command },
                cwd = cwd,
                mode = opts and opts.mode,
            }
        end,
    }
end

return M
