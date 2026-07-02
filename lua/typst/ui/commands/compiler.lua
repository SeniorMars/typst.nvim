local command = require("typst.ui.commands.util")
local complete = require("typst.ui.commands.complete")

local M = {}

local create = command.create
local opts = command.opts

local function compile_command(api, args)
    api.compiler.compile({
        open = args.bang and true or nil,
        profile = args.args ~= "" and args.args or nil,
    })
end

---Register compile/viewer command bindings.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api

    create(
        "TypstCompile",
        function(args)
            compile_command(api, args)
        end,
        vim.tbl_extend(
            "force",
            opts("Compile the current Typst project", "?", complete.profile),
            {
                bang = true,
            }
        )
    )

    create(
        "TypstCompileSS",
        function(args)
            compile_command(api, args)
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Alias for :TypstCompile for VimTeX muscle memory",
                "?",
                complete.profile
            ),
            {
                bang = true,
            }
        )
    )

    create(
        "TypstCompileSelected",
        function(args)
            api.compiler.compile_selected({
                line1 = args.line1,
                line2 = args.line2,
                range = args.range,
                template = args.args ~= "" and args.args or nil,
            })
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Compile the selected Typst fragment",
                "?",
                complete.fragment_template
            ),
            {
                range = true,
            }
        )
    )

    create("TypstCompileOutput", function()
        api.compiler.output({ notify = true })
    end, opts("Open the current project's Typst compiler output"))

    create(
        "TypstWatch",
        function(args)
            api.compiler.watch({
                open = args.bang and true or nil,
                profile = args.args ~= "" and args.args or nil,
            })
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Start or restart Typst watch for the current project",
                "?",
                complete.profile
            ),
            {
                bang = true,
            }
        )
    )

    create("TypstStop", function()
        api.compiler.stop()
    end, opts("Stop Typst watch for the current project"))

    create("TypstStopAll", function()
        api.compiler.stop_all()
    end, opts("Stop active Typst compilers for all known projects"))

    create(
        "TypstCompilerForceClear",
        function(args)
            api.compiler.force_clear({
                force = args.bang == true,
                key = args.args ~= "" and args.args or nil,
                key_encoded = args.args ~= "",
            })
        end,
        vim.tbl_extend(
            "force",
            opts(
                "Discard unconfirmed external compiler state after stop timeout",
                "?",
                complete.retained_project_key
            ),
            {
                bang = true,
            }
        )
    )

    create("TypstView", function()
        api.viewer.view()
    end, opts("Open the current project's generated output"))

    create(
        "TypstViewForward",
        function()
            api.viewer.view_forward()
        end,
        opts(
            "Forward-search the current position in the configured Typst viewer"
        )
    )

    create("TypstViewInverse", function(args)
        api.viewer.view_inverse({
            path = args.fargs[1],
            line = args.fargs[2],
            column = args.fargs[3],
        })
    end, opts("Inverse-search a viewer source location", "*", "file"))

    create(
        "TypstClean",
        function(args)
            api.viewer.clean({ all = args.bang })
        end,
        vim.tbl_extend(
            "force",
            opts("Clean temporary artifacts; bang also requests output cleanup"),
            {
                bang = true,
            }
        )
    )

    create("TypstDiagnostics", function()
        api.diagnostics.quickfix()
    end, opts("Open current Typst compiler diagnostics in quickfix"))

    create("TypstErrors", function()
        api.diagnostics.errors()
    end, opts("Open current Typst compiler diagnostics in quickfix"))
end

return M
