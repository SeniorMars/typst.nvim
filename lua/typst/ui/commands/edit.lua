local command = require("typst.ui.commands.util")
local complete = require("typst.ui.commands.complete")

local M = {}

local create = command.create
local opts = command.opts

local function reports()
    return require("typst.ui.reports")
end

---Register edit-transform command bindings.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api

    create("TypstPromoteHeading", function()
        api.edit.promote_heading()
    end, opts("Promote the current Typst heading through Tinymist"))

    create("TypstDemoteHeading", function()
        api.edit.demote_heading()
    end, opts("Demote the current Typst heading through Tinymist"))

    create("TypstRefreshFolds", function()
        api.edit.refresh_folds()
    end, opts("Refresh Typst folds for the current buffer"))

    create("TypstMatchHighlightEnable", function()
        api.match_highlight.enable()
    end, opts("Enable Typst matching-pair highlighting"))

    create("TypstMatchHighlightDisable", function()
        api.match_highlight.disable()
    end, opts("Disable Typst matching-pair highlighting"))

    create("TypstMatchHighlightToggle", function()
        api.match_highlight.toggle()
    end, opts("Toggle Typst matching-pair highlighting"))

    create("TypstMatchHighlightRefresh", function()
        api.match_highlight.refresh()
    end, opts("Refresh Typst matching-pair highlighting"))

    create("TypstUnwrapFunction", function()
        api.edit.unwrap_function()
    end, opts("Unwrap the surrounding Typst function call"))

    create("TypstChangeFunction", function(args)
        api.edit.change_function(args.args)
    end, opts("Change the surrounding Typst function name", 1))

    create("TypstSurroundDeleteCall", function()
        api.edit.surround_delete_call()
    end, opts("Delete the surrounding Typst function call"))

    create("TypstSurroundChangeCall", function(args)
        api.edit.surround_change_call(args.args)
    end, opts("Change the surrounding Typst function call", 1))

    create(
        "TypstChangeDelimiter",
        function(args)
            api.edit.change_delimiter(args.args)
        end,
        opts(
            "Change the surrounding Typst delimiter pair",
            1,
            complete.delimiter
        )
    )

    create(
        "TypstSurroundDeleteDelimiter",
        function(args)
            api.edit.surround_delete_delimiter(
                args.args ~= "" and args.args or nil
            )
        end,
        opts(
            "Delete the surrounding Typst delimiter pair",
            "?",
            complete.delimiter
        )
    )

    create(
        "TypstSurroundChangeDelimiter",
        function(args)
            api.edit.surround_change_delimiter(args.args)
        end,
        opts(
            "Change the surrounding Typst delimiter pair",
            1,
            complete.delimiter
        )
    )

    create("TypstSurroundDeleteBlock", function()
        api.edit.surround_delete_block()
    end, opts("Delete the surrounding Typst code block delimiters"))

    create(
        "TypstSurroundChangeBlock",
        function(args)
            api.edit.surround_change_block(args.args ~= "" and args.args or nil)
        end,
        opts(
            "Change the surrounding Typst code block delimiters",
            "?",
            complete.delimiter
        )
    )

    create("TypstSurroundDeleteEquation", function()
        api.edit.surround_delete_equation()
    end, opts("Delete the surrounding Typst equation delimiters"))

    create(
        "TypstSurroundChangeEquation",
        function(args)
            api.edit.surround_change_equation(
                args.args ~= "" and args.args or nil
            )
        end,
        opts(
            "Change the surrounding Typst equation delimiters",
            "?",
            complete.delimiter
        )
    )

    create("TypstSplitArguments", function()
        api.edit.split_arguments()
    end, opts("Split the surrounding Typst function argument list"))

    create("TypstJoinArguments", function()
        api.edit.join_arguments()
    end, opts("Join the surrounding Typst function argument list"))

    create(
        "TypstToggleArguments",
        function()
            api.edit.toggle_arguments()
        end,
        opts(
            "Toggle the surrounding Typst function argument list between split and joined form"
        )
    )

    create(
        "TypstNameArguments",
        function()
            api.edit.name_arguments()
        end,
        opts(
            "Convert positional arguments to named arguments for a local Typst function call"
        )
    )

    create(
        "TypstToggleTrailingComma",
        function(args)
            api.edit.toggle_trailing_comma(
                args.args ~= "" and args.args or "toggle"
            )
        end,
        opts(
            "Toggle the trailing comma in a multiline Typst function argument list",
            "?",
            complete.trailing_comma
        )
    )

    create(
        "TypstAddTrailingComma",
        function()
            api.edit.add_trailing_comma()
        end,
        opts("Add a trailing comma to a multiline Typst function argument list")
    )

    create(
        "TypstRemoveTrailingComma",
        function()
            api.edit.remove_trailing_comma()
        end,
        opts(
            "Remove the trailing comma from a multiline Typst function argument list"
        )
    )

    create(
        "TypstToggleLabel",
        function()
            api.edit.toggle_label()
        end,
        opts(
            "Toggle the surrounding Typst label between shorthand and explicit form"
        )
    )

    create(
        "TypstToggleReference",
        function()
            api.edit.toggle_reference()
        end,
        opts(
            "Toggle the surrounding Typst reference between shorthand and explicit form"
        )
    )

    create(
        "TypstToggleLabelReference",
        function()
            api.edit.toggle_label_reference()
        end,
        opts(
            "Toggle the surrounding Typst label or reference between shorthand and explicit form"
        )
    )

    create(
        "TypstSurround",
        function(args)
            local parts =
                vim.split(args.args or "", "%s+", { trimempty = true })
            local range_opts = command.range_opts(args)
            if parts[1] == "function" then
                range_opts.name = parts[2]
            end
            api.edit.surround(parts[1], range_opts)
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Surround the current Typst line or range",
                "+",
                complete.surround
            ),
            {
                range = true,
            }
        )
    )

    create(
        "TypstSurroundFunction",
        function(args)
            api.edit.surround_function(args.args, command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Surround the current Typst line or range with a function call",
                1
            ),
            {
                range = true,
            }
        )
    )

    create(
        "TypstSurroundContent",
        function(args)
            api.edit.surround_content(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Surround the current Typst line or range with content brackets"
            ),
            {
                range = true,
            }
        )
    )

    create(
        "TypstSurroundEquation",
        function(args)
            api.edit.surround_equation(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Surround the current Typst line or range with equation delimiters"
            ),
            {
                range = true,
            }
        )
    )

    create(
        "TypstSurroundFigure",
        function(args)
            api.edit.surround_figure(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts("Surround the current Typst line or range with a figure"),
            {
                range = true,
            }
        )
    )

    create(
        "TypstSurroundBlock",
        function(args)
            api.edit.surround_block(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts("Surround the current Typst line or range with a code block"),
            {
                range = true,
            }
        )
    )

    create(
        "TypstSurroundStrong",
        function(args)
            api.edit.surround_strong(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts("Surround the current Typst line or range with strong markup"),
            {
                range = true,
            }
        )
    )

    create(
        "TypstSurroundEmph",
        function(args)
            api.edit.surround_emph(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Surround the current Typst line or range with emphasis markup"
            ),
            {
                range = true,
            }
        )
    )

    create("TypstToggleStrong", function()
        api.edit.toggle_strong()
    end, opts("Toggle Typst strong markup and #strong[...] form"))

    create("TypstToggleEmph", function()
        api.edit.toggle_emph()
    end, opts("Toggle Typst emphasis markup and #emph[...] form"))

    create("TypstInsert", function(args)
        api.edit.insert(args.args ~= "" and args.args or "math")
    end, opts("Insert a paired Typst markup helper", "?", complete.insert))

    create(
        "TypstImapsList",
        function(args)
            local lines = api.imaps.lines(0)
            if args.bang then
                reports().open_scratch_buffer(
                    "typst.nvim imaps",
                    "typstimaps",
                    lines
                )
            else
                reports().echo_lines(lines)
            end
        end,
        vim.tbl_extend(
            "force",
            opts("List Typst insert-mode mappings"),
            { bang = true }
        )
    )

    create(
        "TypstToggleFigure",
        function(args)
            api.edit.toggle_figure(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts("Toggle Typst figure wrapping for the current line or range"),
            {
                range = true,
            }
        )
    )

    create(
        "TypstToggleList",
        function(args)
            api.edit.toggle_list(
                args.args ~= "" and args.args or "toggle",
                command.range_opts(args)
            )
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Toggle Typst list markers for the current line or range",
                "?",
                complete.list_mode
            ),
            {
                range = true,
            }
        )
    )

    create(
        "TypstToggleBulletList",
        function(args)
            api.edit.toggle_bullet_list(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Toggle Typst bullet list markers for the current line or range"
            ),
            {
                range = true,
            }
        )
    )

    create(
        "TypstToggleNumberedList",
        function(args)
            api.edit.toggle_numbered_list(command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Toggle Typst numbered list markers for the current line or range"
            ),
            {
                range = true,
            }
        )
    )

    create(
        "TypstConvertEquation",
        function(args)
            api.edit.convert_equation(args.args ~= "" and args.args or "toggle")
        end,
        opts(
            "Convert the current Typst equation between inline and block form",
            "?",
            complete.equation_mode
        )
    )

    create(
        "TypstToggleEquationNumbering",
        function(args)
            api.edit.toggle_equation_numbering(
                args.args ~= "" and args.args or "toggle"
            )
        end,
        opts(
            "Toggle numbering for the current Typst equation",
            "?",
            complete.equation_numbering
        )
    )

    create(
        "TypstToggleFraction",
        function()
            api.edit.toggle_fraction()
        end,
        opts("Toggle a simple Typst fraction between slash and frac(...) form")
    )

    create("TypstToggleDelimiterSize", function()
        api.edit.toggle_delimiter_size()
    end, opts(
        "Toggle simple Typst delimiters between plain and lr(...) form"
    ))

    create("TypstToggleLineBreak", function()
        api.edit.toggle_line_break()
    end, opts("Toggle a Typst markup line break at the current line"))

    create(
        "TypstCreateFunction",
        function(args)
            api.edit.create_function(args.args, command.range_opts(args))
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Create a Typst function call from the current word or range",
                1
            ),
            {
                range = true,
            }
        )
    )

    create("TypstSmartClose", function()
        api.edit.smart_close()
    end, opts("Insert the nearest Typst closing delimiter"))

    create(
        "TypstConvertRaw",
        function(args)
            api.edit.convert_raw(args.args ~= "" and args.args or "toggle")
        end,
        opts(
            "Convert the current Typst raw text between inline and block form",
            "?",
            complete.raw_mode
        )
    )
end

return M
