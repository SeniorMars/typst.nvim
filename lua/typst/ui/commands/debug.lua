local command = require("typst.ui.commands.util")
local log = require("typst.core.log")

local M = {}

local create = command.create
local opts = command.opts

local function notify(ctx, message, level)
    ctx.notify(message, level or vim.log.levels.INFO)
end

local function run_invariant_check(ctx)
    local result = require("typst.internal.debug").check_invariants()
    if result.ok then
        notify(
            ctx,
            ("Typst invariants OK: %d projects, %d buffers, %d operations, %d leases"):format(
                result.projects or 0,
                result.attached_buffers or 0,
                result.active_operations or 0,
                result.active_leases or 0
            )
        )
        return result
    end

    log.add("error", "Typst invariant check failed", result)
    notify(
        ctx,
        ("Typst invariant check failed: %d findings"):format(
            #(result.findings or {})
        ),
        vim.log.levels.ERROR
    )
    return result
end

function M.register(ctx)
    create("TypstCheckInvariants", function()
        run_invariant_check(ctx)
    end, opts("Check typst.nvim runtime invariants"))

    create("TypstDoctor", function()
        run_invariant_check(ctx)
    end, opts("Check typst.nvim runtime invariants and lifecycle ownership"))

    create("TypstTelemetry", function()
        local lines = require("typst.internal.debug").telemetry_report()
        if #lines == 0 then
            notify(ctx, "No Typst telemetry recorded")
            return
        end

        notify(ctx, table.concat(lines, "\n"))
    end, opts("Show typst.nvim performance telemetry"))

    create("TypstTelemetryReset", function()
        require("typst.internal.debug").reset_telemetry()
        notify(ctx, "Typst telemetry reset")
    end, opts("Reset typst.nvim performance telemetry"))
end

return M
