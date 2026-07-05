local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry = require("typst.project")
local project_store = require("typst.project.store")
local typst = require("typst")

local main = root .. "/tests/fixtures/basic/main.typ"

local function compile_current_project(message)
    local done = false
    typst.compiler.compile({}, function(result)
        assert(result.code == 0, message)
        done = true
    end)
    assert(
        vim.wait(10000, function()
            return done
        end, 20),
        message
    )
end

local function edit_main()
    vim.cmd.edit(main)
    return typst.project.set_main(main)
end

local function assert_callback_error(result, action)
    assert(
        result and result.ok == false,
        action .. " callback error should return a failed result"
    )
    assert(
        result.reason == "callback_error",
        action .. " callback error should report callback_error"
    )
    assert(
        result.provider == "callback",
        action .. " callback error should report callback provider"
    )
    assert(
        result.action == action,
        action .. " callback error should report action"
    )
    assert(
        tostring(result.error):find(action .. " exploded", 1, true),
        action .. " callback error should expose error"
    )
end

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-callback-error-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            return {
                ok = true,
                pending = true,
            }
        end,
    },
})
local pending_stop_project = edit_main()
assert(
    typst.viewer.preview({ notify = false }) == true,
    "pending stop fixture should open a preview first"
)
local pending_stop_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewStopped",
    callback = function(args)
        pending_stop_event = args.data
    end,
})
local pending_stop = typst.viewer.preview_stop({ notify = false })
assert(
    pending_stop and pending_stop.pending == true,
    "pending preview stop should return the pending result"
)
assert(
    pending_stop_event == nil,
    "pending preview stop should not emit TypstPreviewStopped"
)
assert(
    typst_test_preview(pending_stop_project).active == true,
    "pending preview stop should retain active preview ownership"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-callback-error-output"),
    preview = {
        open = function()
            error("open exploded")
        end,
    },
})
local open_project = edit_main()
local open_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewOpened",
    callback = function(args)
        open_event = args.data
    end,
})
local open_result = typst.viewer.preview({ notify = false })
assert_callback_error(open_result, "open")
assert(
    open_event == nil,
    "failed preview open callback should not emit TypstPreviewOpened"
)
assert(
    typst_test_preview(open_project).active == false,
    "failed preview open callback should not mark preview active"
)
assert(
    typst_test_preview(open_project).last_backend == nil,
    "failed preview open callback should not record stale backend"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-callback-declined-output"),
    preview = {
        open = function()
            return {
                ok = false,
                reason = "declined",
                message = "preview callback declined",
            }
        end,
    },
})
local declined_project = edit_main()
open_event = nil
local declined_result = typst.viewer.preview({ notify = false })
assert(
    declined_result and declined_result.ok == false,
    "declined preview open callback should return a failed result"
)
assert(
    declined_result.reason == "declined",
    "declined preview open callback should preserve failure reason"
)
assert(
    open_event == nil,
    "declined preview open callback should not emit TypstPreviewOpened"
)
assert(
    typst_test_preview(declined_project).active == false,
    "declined preview open callback should not mark preview active"
)
assert(
    typst_test_preview(declined_project).last_backend == nil,
    "declined preview open callback should not record stale backend"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-callback-error-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            error("stop exploded")
        end,
    },
})
local stop_project = edit_main()
assert(
    typst.viewer.preview({ notify = false }) == true,
    "stop error fixture should open a preview first"
)
local stop_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewStopped",
    callback = function(args)
        stop_event = args.data
    end,
})
local stop_result = typst.viewer.preview_stop({ notify = false })
assert_callback_error(stop_result, "stop")
assert(
    stop_event == nil,
    "failed user preview stop callback should not emit TypstPreviewStopped"
)
assert(
    typst_test_preview(stop_project).active == true,
    "failed user preview stop should keep active preview state"
)
local stop_bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(stop_bufnr)
assert(
    typst_test_preview(stop_project).active == true,
    "lifecycle detach should keep failed preview stop state"
)
assert(
    typst_test_preview(stop_project).status == "stopping_failed",
    "lifecycle detach should mark failed preview stop in preview state"
)
assert(
    typst_test_compiler(stop_project).status ~= "stopping_failed",
    "lifecycle detach should not mark preview failure as compiler failure"
)
assert(
    project_store.all()[stop_project.key]
        and project_store.all()[stop_project.key].key == stop_project.key,
    "lifecycle detach should retain failed preview project"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-callback-error-output"),
    preview = {
        forward = function()
            error("forward exploded")
        end,
    },
})
edit_main()
compile_current_project(
    "compile failed before preview forward callback error test"
)
local forward_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewForwarded",
    callback = function(args)
        forward_event = args.data
    end,
})
local forward_result =
    typst.viewer.view_forward({ line = 2, column = 3, notify = false })
assert_callback_error(forward_result, "forward")
assert(
    forward_event == nil,
    "failed preview forward callback should not emit TypstPreviewForwarded"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-callback-error-output"),
    preview = {
        inverse = function()
            error("inverse exploded")
        end,
    },
})
edit_main()
local inverse_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewInverse",
    callback = function(args)
        inverse_event = args.data
    end,
})
local inverse_result = typst.viewer.preview_inverse({
    path = main,
    line = 2,
    column = 3,
    notify = false,
})
assert_callback_error(inverse_result, "inverse")
assert(
    inverse_event == nil,
    "failed preview inverse callback should not emit TypstPreviewInverse"
)

vim.cmd("qa!")
