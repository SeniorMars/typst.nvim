local command = require("typst.ui.commands.util")
local complete = require("typst.ui.commands.complete")
local util = require("typst.core.util")

local M = {}

local create = command.create
local opts = command.opts

local function reports()
    return require("typst.ui.reports")
end

local function artifact_lines(items)
    local lines = { "typst.nvim artifacts" }
    if #items == 0 then
        lines[#lines + 1] = "No artifacts are registered"
        return lines
    end
    for _, item in ipairs(items) do
        local preview_export = item.preview_export
        local detail = ""
        if type(preview_export) == "table" then
            local fields = {}
            if preview_export.target then
                fields[#fields + 1] = ("target=%s"):format(
                    preview_export.target
                )
            end
            if preview_export.mode then
                fields[#fields + 1] = ("mode=%s"):format(preview_export.mode)
            end
            if preview_export.profile then
                fields[#fields + 1] = ("profile=%s"):format(
                    preview_export.profile
                )
            end
            if #fields > 0 then
                detail = "  " .. table.concat(fields, " ")
            end
        end
        lines[#lines + 1] = ("%s  %s  %s  %s%s"):format(
            item.format or "file",
            item.status or "unknown",
            item.producer or "document",
            item.path or "",
            detail
        )
    end
    return lines
end

local function split_args(args)
    local values = {}
    for value in (args or ""):gmatch("%S+") do
        values[#values + 1] = value
    end
    return values
end

local function export_opts(argument)
    if argument == nil or argument == "" then
        return {}
    end

    local exports = require("typst.config").unsafe_get().exports or {}
    local profiles = exports.profiles or exports
    if type(profiles) == "table" and profiles[argument] ~= nil then
        return { profile = argument }
    end
    return { format = argument }
end

--- Register artifact, template, bibliography, and development workflow commands.
---@param ctx table Runtime command context with `api` and notification helpers.
function M.register(ctx)
    local api = ctx.api

    create(
        "TypstExport",
        function(args)
            local export = export_opts(args.args)
            export.open = args.bang and true or nil
            return api.artifact.export(export)
        end,
        vim.tbl_extend(
            "force",
            opts("Export one or more Typst artifacts", "?", complete.export),
            {
                bang = true,
            }
        )
    )

    create("TypstArtifacts", function()
        local items, err = api.artifact.list()
        if not items then
            return nil, err
        end
        reports().open_scratch_buffer(
            "typst.nvim artifacts",
            "typstartifacts",
            artifact_lines(items)
        )
        return items
    end, opts("List current Typst project artifacts"))

    create("TypstArtifactOpen", function(args)
        return api.artifact.open({
            format = args.args ~= "" and args.args or nil,
            prompt = true,
        })
    end, opts("Open a generated Typst artifact", "?", complete.export))

    create("TypstArtifactClean", function(args)
        return api.artifact.clean({
            format = args.args ~= "" and args.args or nil,
        })
    end, opts("Clean generated Typst artifacts", "?", complete.export))

    create(
        "TypstEval",
        function(args)
            return api.evaluation.eval({
                expression = args.args,
                open = args.bang or nil,
            })
        end,
        vim.tbl_extend("force", opts("Evaluate a Typst expression", "+"), {
            bang = true,
        })
    )

    create(
        "TypstEvalSelection",
        function(args)
            return api.evaluation.selection({
                line1 = args.line1,
                line2 = args.line2,
                range = args.range,
                open = args.bang or nil,
            })
        end,
        vim.tbl_extend("force", opts("Evaluate the selected Typst source"), {
            bang = true,
            range = true,
        })
    )

    create(
        "TypstInspect",
        function(args)
            return api.evaluation.inspect({
                expression = args.args ~= "" and args.args or nil,
                open = args.bang or nil,
            })
        end,
        vim.tbl_extend("force", opts("Inspect a Typst expression", "?"), {
            bang = true,
        })
    )

    create(
        "TypstInit",
        function(args)
            local values = split_args(args.args)
            return api.template.init({
                template = values[1],
                directory = values[2],
                select = values[1] == nil,
                open = not args.bang,
            })
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Initialize a Typst project from a template",
                "*",
                complete.package
            ),
            {
                bang = true,
            }
        )
    )

    create("TypstTemplates", function()
        return api.template.list({ open = true })
    end, opts("List cached Typst templates"))

    create(
        "TypstProfile",
        function(args)
            return api.development.profile({
                profile = args.args ~= "" and args.args or nil,
                open = not args.bang,
            })
        end,
        vim.tbl_extend(
            "force",
            opts("Profile a Typst compile", "?", complete.profile),
            {
                bang = true,
            }
        )
    )

    create("TypstTest", function(args)
        return api.development.test({ args = args.args })
    end, opts("Run Typst project tests through a provider", "*"))

    create("TypstBench", function(args)
        return api.development.bench({ args = args.args })
    end, opts("Run Typst project benchmarks through a provider", "*"))

    create("TypstCoverage", function(args)
        return api.development.coverage({ args = args.args })
    end, opts("Run Typst project coverage through a provider", "*"))

    create("TypstInlayHintsToggle", function()
        return api.semantic.inlay_hints_toggle()
    end, opts("Toggle Typst inlay hints"))

    local function ignore_async_result() end

    create("TypstCodeAction", function(args)
        local index = tonumber(args.args)
        return api.semantic.code_action({
            index = index,
            open = index == nil,
            callback = ignore_async_result,
        })
    end, opts("List or apply Tinymist code actions", "?"))

    create("TypstColorInfo", function()
        return api.semantic.color_info({
            open = true,
            callback = ignore_async_result,
        })
    end, opts("List Typst color information from LSP"))

    create("TypstColorPresentation", function(args)
        local index = tonumber(args.args)
        return api.semantic.color_presentation({
            index = index,
            open = index == nil,
            callback = ignore_async_result,
        })
    end, opts("List or apply Tinymist color presentations", "?"))

    create("TypstLinks", function()
        return api.semantic.document_links({
            open = true,
            callback = ignore_async_result,
        })
    end, opts("List Typst document links from LSP"))

    create("TypstCodeLens", function()
        return api.semantic.code_lens({ callback = ignore_async_result })
    end, opts("Refresh Typst code lenses"))

    create("TypstWorkspaceSymbols", function(args)
        return api.semantic.workspace_symbols({
            query = args.args,
            open = true,
            callback = ignore_async_result,
        })
    end, opts("List Typst workspace symbols", "*"))

    create("TypstReferences", function()
        return api.semantic.references({
            open = true,
            callback = ignore_async_result,
        })
    end, opts("List Typst references under cursor"))

    create("TypstRenamePreview", function(args)
        return api.semantic.rename_preview({
            new_name = args.args,
            open = true,
            callback = ignore_async_result,
        })
    end, opts("Preview a Typst rename workspace edit", "+"))

    create("TypstSelectionExpand", function()
        return api.semantic.selection_expand({ callback = ignore_async_result })
    end, opts("Request Typst semantic selection ranges"))

    create("TypstOnEnter", function()
        return api.semantic.on_enter({ callback = ignore_async_result })
    end, opts("Apply Tinymist experimental on-enter edits"))

    create("TypstHtmlPreview", function(args)
        return api.artifact.html_preview({
            profile = args.args ~= "" and args.args or nil,
        })
    end, opts(
        "Export the current Typst project as HTML",
        "?",
        complete.export
    ))

    create(
        "TypstPresentation",
        function(args)
            return api.artifact.presentation({
                profile = args.args ~= "" and args.args or nil,
            })
        end,
        opts(
            "Export the current Typst project using presentation settings",
            "?",
            complete.export
        )
    )
end

return M
