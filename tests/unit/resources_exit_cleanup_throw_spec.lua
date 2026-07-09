local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local compiler = require("typst.compiler")
local operations = require("typst.project.services.operations")
local preview = require("typst.preview.controller")
local preview_service = require("typst.project.services.preview")
local project_store = require("typst.project.store")
local resource_manager = require("typst.runtime.resource_manager")
local typst = require("typst")

typst.reset({ force = true })

local fixture_root = typst_test_cache_path("resources-exit-cleanup")
vim.fn.mkdir(fixture_root, "p")
local main_a = fixture_root .. "/a.typ"
local main_b = fixture_root .. "/b.typ"
vim.fn.writefile({ "= A" }, main_a)
vim.fn.writefile({ "= B" }, main_b)

local project_a = project_store.create(fixture_root, main_a)
local project_b = project_store.create(fixture_root, main_b)

local original_stop_for_exit = compiler.stop_for_exit
local original_cancel_project = operations.cancel_project
local original_preview_stop_for_exit = preview.stop_for_exit
local original_preview_clear_state = preview.clear_state

local function reset_calls()
    return {
        compiler = {},
        operations = {},
    }
end

local ok, err = xpcall(function()
    local calls = reset_calls()
    rawset(compiler, "stop_for_exit", function(state)
        calls.compiler[#calls.compiler + 1] = state.key
        if state == project_a then
            error("compiler stop boom")
        end
        return { code = 0, stopped = true }
    end)
    rawset(operations, "cancel_project", function(state)
        calls.operations[#calls.operations + 1] = state.key
        return { failed = 0, retained = 0 }
    end)

    local summary = resource_manager.stop_for_exit_all()
    assert(summary.ok == false, "compiler throw should mark summary failed")
    assert(
        vim.tbl_contains(calls.compiler, project_b.key),
        "compiler stop throw should not skip later projects"
    )
    assert(
        vim.tbl_contains(calls.operations, project_a.key)
            and vim.tbl_contains(calls.operations, project_b.key),
        "operation cancellation should still run for all projects"
    )
    local saw_compiler_error = false
    for _, failure in ipairs(summary.failed or {}) do
        saw_compiler_error = saw_compiler_error
            or failure.reason == "compiler_stop_error"
    end
    assert(saw_compiler_error, "summary should record compiler stop errors")

    calls = reset_calls()
    rawset(compiler, "stop_for_exit", function(state)
        calls.compiler[#calls.compiler + 1] = state.key
        return { code = 0, stopped = true }
    end)
    rawset(operations, "cancel_project", function(state)
        calls.operations[#calls.operations + 1] = state.key
        if state == project_a then
            error("operation cancel boom")
        end
        return { failed = 0, retained = 0 }
    end)

    summary = resource_manager.stop_for_exit_all()
    assert(summary.ok == false, "operation throw should mark summary failed")
    assert(
        vim.tbl_contains(calls.operations, project_b.key),
        "operation cancel throw should not skip later projects"
    )
    local saw_operation_error = false
    for _, failure in ipairs(summary.failed or {}) do
        saw_operation_error = saw_operation_error
            or failure.reason == "operation_cancel_error"
    end
    assert(saw_operation_error, "summary should record operation cancel errors")

    rawset(compiler, "stop_for_exit", function()
        return { code = 0, stopped = true }
    end)
    local timer_for_cancel = vim.uv and vim.uv.new_timer and vim.uv.new_timer()
        or vim.loop.new_timer()
    local incomplete_cancel = {
        failed = 1,
        retained = 0,
        handle = timer_for_cancel,
    }
    incomplete_cancel.self = incomplete_cancel
    rawset(operations, "cancel_project", function(state)
        if state == project_a then
            return incomplete_cancel
        end
        return { failed = 0, retained = 0 }
    end)
    summary = resource_manager.stop_for_exit_all()
    if timer_for_cancel and not timer_for_cancel:is_closing() then
        timer_for_cancel:close()
    end
    local saw_safe_cancel = false
    for _, failure in ipairs(summary.failed or {}) do
        if failure.reason == "operation_cancel_incomplete" then
            saw_safe_cancel = failure.result
                and failure.result.self == "<cycle>"
                and type(failure.result.handle) == "string"
        end
    end
    assert(
        saw_safe_cancel,
        "exit cleanup should safely summarize incomplete operation payloads"
    )

    rawset(operations, "cancel_project", function()
        return { failed = 0, retained = 0 }
    end)

    local live_preview_stop_calls = {}
    rawset(preview, "stop_for_exit", function(state)
        live_preview_stop_calls[#live_preview_stop_calls + 1] = state.key
        return { ok = true, stopped = true }
    end)
    for _, fields in ipairs({
        { opening = true, stopping = false, status = "opening" },
        { opening = false, stopping = true, status = "stopping" },
    }) do
        preview_service.set(
            project_a,
            vim.tbl_extend("force", {
                active = false,
            }, fields)
        )
        summary = resource_manager.stop_for_exit_all()
        assert(summary.ok == true, "live preview exit stop should succeed")
    end
    assert(
        #live_preview_stop_calls == 2,
        "exit cleanup should stop preview opening/stopping states"
    )

    for _, case in ipairs({
        {
            reason = "preview_stop_failed",
            result = {
                ok = false,
                reason = "viewer_error",
            },
        },
        {
            reason = "preview_stop_pending",
            result = {
                pending = true,
                ok = false,
            },
        },
        {
            reason = "preview_stop_declined",
            result = false,
        },
    }) do
        preview_service.set(project_a, {
            active = true,
            active_backend = "native-browser",
        })
        rawset(preview, "stop_for_exit", function()
            return case.result
        end)

        summary = resource_manager.stop_for_exit_all()
        assert(
            summary.ok == false,
            case.reason .. " should mark exit summary failed"
        )
        local saw_preview_result = false
        for _, failure in ipairs(summary.failed or {}) do
            saw_preview_result = saw_preview_result
                or failure.reason == case.reason
        end
        assert(saw_preview_result, "summary should record " .. case.reason)
    end

    local timer = vim.uv and vim.uv.new_timer and vim.uv.new_timer()
        or vim.loop.new_timer()
    local cyclic = {
        ok = false,
        reason = "cyclic_payload",
        handle = timer,
    }
    cyclic.self = cyclic
    preview_service.set(project_a, {
        active = true,
        active_backend = "native-browser",
    })
    rawset(preview, "stop_for_exit", function()
        return cyclic
    end)
    summary = resource_manager.stop_for_exit_all()
    if timer and not timer:is_closing() then
        timer:close()
    end
    local saw_safe_payload = false
    for _, failure in ipairs(summary.failed or {}) do
        if failure.reason == "preview_stop_failed" then
            saw_safe_payload = failure.result
                and failure.result.self == "<cycle>"
                and type(failure.result.handle) == "string"
        end
    end
    assert(
        saw_safe_payload,
        "exit cleanup should safely summarize cyclic/userdata failures"
    )

    preview_service.set(project_a, {
        active = true,
        active_backend = "native-browser",
    })
    rawset(preview, "stop_for_exit", function()
        error("preview stop boom")
    end)
    rawset(preview, "clear_state", function()
        error("preview clear boom")
    end)
    summary = resource_manager.stop_for_exit_all()
    local saw_stop_error = false
    local saw_clear_error = false
    for _, failure in ipairs(summary.failed or {}) do
        saw_stop_error = saw_stop_error
            or failure.reason == "preview_stop_error"
        saw_clear_error = saw_clear_error
            or failure.reason == "preview_clear_error"
    end
    assert(saw_stop_error, "summary should record thrown preview stop errors")
    assert(
        saw_clear_error,
        "summary should record clear_state errors after preview stop throws"
    )
end, debug.traceback)

compiler.stop_for_exit = original_stop_for_exit
operations.cancel_project = original_cancel_project
preview.stop_for_exit = original_preview_stop_for_exit
preview.clear_state = original_preview_clear_state
typst.reset({ force = true })

if not ok then
    error(err)
end

vim.cmd("qa!")
