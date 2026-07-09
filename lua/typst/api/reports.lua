local M = {}
local api_context = require("typst.api.context")
local operation = require("typst.core.operation")
local project_context = require("typst.project.context")

---@class TypstProjectReportOptions
---@field bufnr integer|nil
---@field open boolean|nil
---@field bang boolean|nil
---@field echo boolean|nil
---@field all boolean|nil
---@field detailed boolean|nil
---@field notify boolean|nil
---@field project table|nil
---@field root string|nil
---@field timeout_ms integer|nil

local function info_opts(value)
    if type(value) == "table" then
        return value
    end

    return { bufnr = value }
end

local function project_for_opts(_, opts)
    if type(opts.project) == "table" then
        if opts.project.mutable == false then
            return project_context.live(opts.project)
        end
        return opts.project
    end

    local state = project_context.resolve(opts, { create = false })
    if type(state) == "table" then
        opts.project = state
        return state
    end

    return nil
end

--- Install reporting and tool methods on the public API table.
---@param api table Public API table mutated in place.
---@param notify fun(message:string, level?:vim.log.levels|integer) Notification sink used by report/tool wrappers.
function M.install(api, notify)
    local function attached_project(opts, operation_name, policy)
        policy = vim.tbl_extend("force", {
            create = false,
            settle_pending = true,
            passive = true,
            operation = operation_name,
        }, policy or {})
        local ctx = api_context.project(opts or {}, policy, notify)
        if not ctx.ok then
            return nil, ctx.error
        end
        return ctx.project, nil
    end

    local function no_project_lines(err, bufnr)
        local name = vim.api.nvim_buf_is_valid(bufnr)
                and vim.api.nvim_buf_get_name(bufnr)
            or ""
        local filetype = vim.api.nvim_buf_is_valid(bufnr)
                and vim.bo[bufnr].filetype
            or ""
        return {
            err.message,
            ("Buffer filetype: %s"):format(
                filetype ~= "" and filetype or "<none>"
            ),
            ("Buffer name: %s"):format(name ~= "" and name or "<unnamed>"),
            "Open a Typst buffer, run :setfiletype typst, or pass a project/key.",
        }
    end

    local function info(bufnr)
        local opts = info_opts(bufnr)
        bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
        opts = vim.tbl_extend("force", opts, { bufnr = bufnr })
        local state, err = attached_project(opts, "ui.info", {
            create = true,
            require_typst = true,
        })
        if not state then
            local lines = no_project_lines(err, bufnr)
            if opts.echo ~= false then
                require("typst.ui.reports").echo_lines(lines)
            end
            return nil, lines, nil
        end
        local reports = require("typst.ui.reports")
        local lines = reports.project_lines(state, bufnr, {
            detailed = opts.bang or opts.open,
        })
        local buf = nil
        if opts.bang or opts.open then
            buf = reports.open_scratch_buffer(
                "typst.nvim info",
                "typstinfo",
                lines
            )
        elseif opts.echo ~= false then
            reports.echo_lines(lines)
        end
        return state, lines, buf
    end

    local function status_report(opts)
        opts = opts or {}
        local reports = require("typst.ui.reports")
        local status = require("typst.ui.status")

        if opts.bang or opts.all then
            return api.ui.status_all({ echo = opts.echo, open = opts.open })
        end

        if opts.detailed then
            local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
            local state, err = attached_project(
                vim.tbl_extend("force", opts, { bufnr = bufnr }),
                "ui.status_report",
                {
                    create = true,
                    require_typst = true,
                }
            )
            if not state then
                local lines = no_project_lines(err, bufnr)
                if opts.echo ~= false then
                    reports.echo_lines(lines)
                end
                return nil, lines
            end
            local lines = reports.project_lines(state, bufnr, {
                detailed = opts.detailed,
            })
            if opts.telemetry then
                local snapshot = status.snapshot(bufnr, { telemetry = true })
                local telemetry_lines = snapshot.telemetry_report or {}
                if #telemetry_lines > 0 then
                    lines[#lines + 1] = ""
                    lines[#lines + 1] = "telemetry:"
                    for _, line in ipairs(telemetry_lines) do
                        lines[#lines + 1] = "  " .. line
                    end
                end
            end
            if opts.echo ~= false then
                reports.echo_lines(lines)
            end
            return status.snapshot(bufnr, { telemetry = opts.telemetry }), lines
        end

        local snapshot =
            status.snapshot(opts.bufnr, { telemetry = opts.telemetry })
        local lines = reports.status_report_lines(snapshot)
        if opts.echo ~= false then
            reports.echo_lines(lines)
        end
        return snapshot, lines
    end

    local function status_all(opts)
        opts = opts or {}
        local status = require("typst.ui.status")
        local reports = require("typst.ui.reports")
        local snapshots = {}
        for _, state in pairs(require("typst.project.store").all()) do
            snapshots[#snapshots + 1] = status.project_snapshot(state)
        end
        table.sort(snapshots, function(left, right)
            return (left.main or "") < (right.main or "")
        end)
        local lines = reports.status_all_lines(snapshots)
        if opts.open then
            local buf = reports.open_scratch_buffer(
                "typst.nvim status",
                "typststatus",
                lines
            )
            return snapshots, lines, buf
        end
        if opts.echo ~= false then
            reports.echo_lines(lines)
        end
        return snapshots, lines
    end

    local function explain_project(opts)
        opts = opts or {}
        local reports = require("typst.ui.reports")
        local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
        local state, err = attached_project(
            vim.tbl_extend("force", opts, { bufnr = bufnr }),
            "ui.explain_project",
            {
                create = true,
                require_typst = true,
                settle_pending = opts.settle_pending ~= false,
            }
        )
        if not state then
            local lines = no_project_lines(err, bufnr)
            local failure = vim.tbl_extend("force", err or {}, {
                ok = false,
                reason = err and err.reason or "no_project",
                message = lines[1],
                lines = lines,
            })
            if opts.echo ~= false then
                reports.echo_lines(lines)
            end
            return failure, lines
        end

        local explanation =
            require("typst.project.explain").report(state, bufnr)
        local lines = explanation.lines
        local buf = nil
        if opts.open then
            buf = reports.open_scratch_buffer(
                "typst.nvim project explanation",
                "typstinfo",
                lines
            )
        elseif opts.echo ~= false then
            reports.echo_lines(lines)
        end
        return explanation, lines, buf
    end

    local function bug_report(opts)
        opts = opts or {}
        local result = require("typst").report(opts)
        if opts.echo ~= false then
            if result.ok then
                if result.path then
                    notify(
                        ("Typst bug report written to %s"):format(result.path)
                    )
                elseif result.buffer then
                    notify("Typst bug report opened")
                else
                    notify("Typst bug report generated")
                end
            else
                notify(
                    result.message or "Typst bug report failed",
                    vim.log.levels.ERROR
                )
            end
        end
        return result
    end

    local function count(opts)
        opts = opts or {}
        local count = require("typst.diagnostics.count")
        local reports = require("typst.ui.reports")
        local result = count.count(opts)
        if opts.echo ~= false then
            reports.echo_lines({ count.format(result) })
        end
        return result
    end

    local function format(opts, callback)
        opts = opts or {}
        local function notify_result(result)
            if opts.notify == false or type(result) ~= "table" then
                return
            end
            if result.ok then
                if result.changed then
                    notify(
                        ("Formatted Typst buffer with %s"):format(
                            result.provider or "formatter"
                        )
                    )
                else
                    notify("Typst buffer already formatted")
                end
            else
                notify(
                    result.message or "Typst formatting failed",
                    vim.log.levels.WARN
                )
            end
        end

        return operation.notify_result(function(callback)
            return require("typst.project.services.operations").format(
                project_for_opts(api, opts),
                opts,
                callback
            )
        end, {
            notify_result = notify_result,
            start_message = opts.notify ~= false and "Formatting Typst buffer"
                or nil,
            notify = notify,
            callback = callback,
        })
    end

    local function lint(opts, callback)
        opts = opts or {}
        local function notify_result(result)
            if opts.notify == false or type(result) ~= "table" then
                return
            end
            if result.ok then
                local total = result.diagnostics or 0
                notify(
                    ("Typst lint: %d diagnostic%s"):format(
                        total,
                        total == 1 and "" or "s"
                    ),
                    total > 0 and vim.log.levels.WARN or vim.log.levels.INFO
                )
            else
                notify(
                    result.message or "Typst lint failed",
                    vim.log.levels.WARN
                )
            end
        end

        return operation.notify_result(function(callback)
            return require("typst.project.services.operations").lint(
                project_for_opts(api, opts),
                opts,
                callback
            )
        end, {
            notify_result = notify_result,
            start_message = opts.notify ~= false and "Running Typst lint"
                or nil,
            notify = notify,
            callback = callback,
        })
    end

    local function grammar(opts, callback)
        opts = opts or {}
        local function notify_result(result)
            if opts.notify == false or type(result) ~= "table" then
                return
            end
            if result.ok then
                local total = result.diagnostics or 0
                notify(
                    ("Typst grammar: %d diagnostic%s"):format(
                        total,
                        total == 1 and "" or "s"
                    ),
                    total > 0 and vim.log.levels.WARN or vim.log.levels.INFO
                )
            else
                notify(
                    result.message or "Typst grammar check failed",
                    vim.log.levels.WARN
                )
            end
        end

        return operation.notify_result(function(callback)
            return require("typst.project.services.operations").grammar(
                project_for_opts(api, opts),
                opts,
                callback
            )
        end, {
            notify_result = notify_result,
            start_message = opts.notify ~= false
                    and "Running Typst grammar check"
                or nil,
            notify = notify,
            callback = callback,
        })
    end

    local function status(bufnr)
        if type(bufnr) == "table" then
            local status_opts = bufnr
            return require("typst.ui.status").snapshot(
                status_opts.bufnr,
                status_opts
            )
        end
        return require("typst.ui.status").snapshot(bufnr)
    end

    local function statusline(opts)
        return require("typst.ui.status").statusline(opts)
    end

    local function log()
        return require("typst.core.log").entries()
    end

    api.ui = {
        info = info,
        status = status,
        status_report = status_report,
        status_all = status_all,
        explain_project = explain_project,
        bug_report = bug_report,
        statusline = statusline,
        count = count,
        log = log,
    }

    api.tools = {
        format = format,
        lint = lint,
        grammar = grammar,
    }
end

return M
