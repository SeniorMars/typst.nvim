local command = require("typst.ui.commands.util")
local log = require("typst.core.log")

local M = {}

local create = command.create
local opts = command.opts

---Register project/project-state user commands.
---@param ctx table runtime context with `api` field.
function M.register(ctx)
    local api = ctx.api

    create(
        "TypstInfo",
        function(args)
            return api.ui.info({ bang = args.bang })
        end,
        vim.tbl_extend("force", opts("Show resolved Typst project state"), {
            bang = true,
        })
    )

    create("TypstReloadState", function()
        return api.project.reload_state()
    end, opts("Reload typst.nvim state for the current buffer"))

    create("TypstClearCache", function()
        return api.project.clear_cache()
    end, opts(
        "Clear typst.nvim metadata, package, symbol, and conceal caches"
    ))

    create(
        "TypstExplainProject",
        function(args)
            local result, lines, buf = api.ui.explain_project({
                open = args.bang,
                echo = not args.bang,
            })
            if type(result) == "table" and result.ok == false then
                if args.bang then
                    local reports = require("typst.ui.reports")
                    reports.open_scratch_buffer(
                        "typst.nvim project explanation",
                        "typstinfo",
                        lines or result.lines or { result.message }
                    )
                end
                return nil
            end
            return result, lines, buf
        end,
        vim.tbl_extend("force", opts("Explain Typst project resolution"), {
            bang = true,
        })
    )

    create("TypstLocks", function(args)
        local reports = require("typst.ui.reports")
        reports.echo_lines(reports.output_lock_lines({
            path = args.args ~= "" and args.args or nil,
        }))
    end, opts("List typst.nvim output locks", "?", "file"))

    create(
        "TypstCleanLocks",
        function(args)
            local reports = require("typst.ui.reports")
            reports.echo_lines(reports.clean_output_locks_lines({
                force = args.bang,
                path = args.args ~= "" and args.args or nil,
            }))
        end,
        vim.tbl_extend(
            "force",
            opts("Clean stale typst.nvim output locks", "?", "file"),
            {
                bang = true,
            }
        )
    )

    create(
        "TypstSetMain",
        function(args)
            return api.project.set_main(args.args, nil, {
                persist = true,
                force = args.bang,
            })
        end,
        vim.tbl_extend(
            "force",
            opts("Set the current buffer's Typst main file", "?", "file"),
            { bang = true }
        )
    )

    create("TypstToggleMain", function()
        return api.project.toggle_main()
    end, opts("Toggle the current buffer between local and project main"))

    create("TypstEditMain", function()
        return api.project.edit_main()
    end, opts("Edit the resolved Typst main file"))

    create("TypstFiles", function()
        return api.navigation.files()
    end, opts("List files in the resolved Typst project"))

    create(
        "TypstCd",
        function(args)
            return api.project.cd({ global = args.bang })
        end,
        vim.tbl_extend(
            "force",
            opts("Change directory to the resolved Typst project root"),
            {
                bang = true,
            }
        )
    )

    create(
        "TypstStatus",
        function(args)
            return api.ui.status_report({ bang = args.bang })
        end,
        vim.tbl_extend("force", opts("Show current Typst project status"), {
            bang = true,
        })
    )

    create(
        "TypstStatusAll",
        function(args)
            return api.ui.status_all({ open = args.bang })
        end,
        vim.tbl_extend(
            "force",
            opts("Show status for all known Typst projects"),
            {
                bang = true,
            }
        )
    )

    create(
        "TypstCount",
        function(args)
            local has_range = args.range and args.range > 0
            return api.ui.count({
                project = args.bang,
                range = has_range,
                line1 = has_range and args.line1 or nil,
                line2 = has_range and args.line2 or nil,
            })
        end,
        vim.tbl_extend("force", opts("Count Typst words and characters"), {
            bang = true,
            range = true,
        })
    )

    create("TypstFormat", function()
        return api.tools.format()
    end, opts("Format the current Typst buffer"))

    create(
        "TypstLint",
        function(args)
            return api.tools.lint({ open = args.bang })
        end,
        vim.tbl_extend("force", opts("Lint the current Typst project"), {
            bang = true,
        })
    )

    create("TypstLog", function()
        log.open()
    end, opts("Open the typst.nvim log"))
end

return M
