local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry = require("typst.project")
local typst = require("typst")
typst.reset()

local opened = 0
local stopped = 0
local open_mode = nil
local stop_project = nil

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-controls-output"),
    preview = {
        open = function(_, opts)
            opened = opened + 1
            open_mode = opts.mode
            return true
        end,
        stop = function(project)
            stopped = stopped + 1
            stop_project = project
            return true
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local opened_event = nil
local stopped_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewOpened",
    callback = function(args)
        opened_event = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewStopped",
    callback = function(args)
        stopped_event = args.data
    end,
})

assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "preview callback should open"
)
assert(opened == 1, "preview open callback should run")
assert(open_mode == "document", "preview open callback should receive mode")
assert(
    typst_test_preview(project).active == true,
    "project should track active preview after open"
)
assert(
    opened_event and opened_event.preview_active == true,
    "preview open event should report active preview"
)

assert(typst.viewer.preview_stop() == true, "preview stop callback should run")
assert(stopped == 1, "preview stop callback should run once")
assert(
    stop_project.key == project.key,
    "preview stop callback should receive project"
)
assert(
    typst_test_preview(project).active == false,
    "project should track inactive preview after stop"
)
assert(
    stopped_event and stopped_event.preview_active == false,
    "preview stopped event should report inactive preview"
)

assert(
    typst.viewer.preview_toggle({ mode = "slide" }) == true,
    "preview toggle should open when inactive"
)
assert(opened == 2, "preview toggle should call open when inactive")
assert(open_mode == "slide", "preview toggle should pass through mode")
assert(
    typst_test_preview(project).active == true,
    "preview toggle should mark preview active after opening"
)

assert(
    typst.viewer.preview_toggle() == true,
    "preview toggle should stop when active"
)
assert(stopped == 2, "preview toggle should call stop when active")
assert(
    typst_test_preview(project).active == false,
    "preview toggle should mark preview inactive after stopping"
)

vim.cmd("TypstPreviewToggle document")
assert(opened == 3, "TypstPreviewToggle command should open when inactive")
assert(open_mode == "document", "TypstPreviewToggle command should pass mode")

vim.cmd("TypstPreviewStop")
assert(stopped == 3, "TypstPreviewStop command should stop")

vim.cmd("TypstPreview mode=slide")
assert(opened == 4, "TypstPreview should parse key-value mode")
assert(open_mode == "slide", "TypstPreview should pass key-value mode")
vim.cmd("TypstPreviewStop")
assert(stopped == 4, "TypstPreviewStop should stop key-value preview")

assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "preview should reopen before detach"
)
assert(opened == 5, "preview open callback should run before detach")
assert(
    typst_test_preview(project).active == true,
    "project should track active preview before detach"
)
assert(
    typst.viewer.preview({ mode = "slide" }) == true,
    "active preview should be reused by default"
)
assert(opened == 5, "active preview reuse should not call open again")
assert(
    stopped == 4,
    "active preview reuse should not stop the existing preview"
)
assert(
    typst_test_preview(project).last_mode == "document",
    "active preview reuse should preserve the existing preview mode"
)
assert(
    typst.viewer.preview({ mode = "slide", restart = true }) == true,
    "preview restart should stop and reopen"
)
assert(stopped == 5, "preview restart should stop the active preview")
assert(opened == 6, "preview restart should call open again")
assert(open_mode == "slide", "preview restart should pass through the new mode")
assert(
    typst_test_preview(project).last_mode == "slide",
    "preview restart should record the new preview mode"
)
local bufnr = vim.api.nvim_get_current_buf()
local detached = typst.project.detach(bufnr)
assert(
    detached and detached.key == project.key,
    "detach should return the preview project"
)
assert(stopped == 6, "last-buffer detach should stop an active preview")
assert(
    typst_test_preview(project).active == false,
    "last-buffer detach should clear preview active state"
)
assert(
    registry.all()[project.key] == nil,
    "preview project should be pruned after detach stops preview"
)

typst.reset()
opened = 0
stopped = 0
open_mode = nil
stop_project = nil

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-controls-output"),
    preview = {
        open = function(_, opts)
            opened = opened + 1
            open_mode = opts.mode
            return true
        end,
        stop = function(project_to_stop)
            stopped = stopped + 1
            stop_project = project_to_stop
            return true
        end,
    },
})

local chapter = root .. "/tests/fixtures/basic/chapter.typ"
vim.cmd.edit(chapter)
local chapter_project = typst.project.set_main(chapter)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "preview should open for original main before transfer"
)
assert(
    typst_test_preview(chapter_project).active == true,
    "original project should track active preview before transfer"
)

local main_project = typst.project.set_main(main)
assert(
    main_project.key ~= chapter_project.key,
    "changing main should move buffer to another project"
)
assert(
    stopped == 1,
    "changing main should stop active preview for the old project"
)
assert(
    stop_project and stop_project.key == chapter_project.key,
    "preview stop should receive the old project"
)
assert(
    typst_test_preview(chapter_project).active == false,
    "old project preview state should be cleared after main change"
)
assert(
    registry.all()[chapter_project.key] == nil,
    "old preview project should be pruned after main change"
)
assert(
    registry.all()[main_project.key] == main_project,
    "new project should remain registered after preview transfer"
)

typst.reset()
opened = 0
stopped = 0
open_mode = nil

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-controls-output"),
    preview = {
        open = function(_, opts)
            opened = opened + 1
            open_mode = opts.mode
            return true
        end,
    },
})

vim.cmd.edit(main)
project = typst.project.set_main(main)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "unstoppable preview should still open"
)
assert(opened == 1, "unstoppable preview open callback should run")
assert(
    typst_test_preview(project).active == true,
    "unstoppable preview should be tracked before lifecycle cleanup"
)
local unstoppable_bufnr = vim.api.nvim_get_current_buf()
local unstoppable_detached = typst.project.detach(unstoppable_bufnr)
assert(
    unstoppable_detached and unstoppable_detached.key == project.key,
    "detach should return unstoppable preview project"
)
assert(
    typst_test_preview(project).active == true,
    "failed lifecycle cleanup should keep unstoppable preview state"
)
assert(
    typst_test_preview(project).status == "stopping_failed",
    "failed lifecycle cleanup should mark preview stopping failed"
)
assert(
    typst_test_compiler(project).status ~= "stopping_failed",
    "failed preview cleanup should not mark the compiler stopping failed"
)
assert(
    registry.all()[project.key] == project,
    "unstoppable preview project should stay registered after failed stop"
)

typst.reset({ force = true })
opened = 0
stopped = 0
open_mode = nil

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-controls-output"),
    preview = {
        reuse = false,
        open = function(_, opts)
            opened = opened + 1
            open_mode = opts.mode
            return true
        end,
        stop = function()
            stopped = stopped + 1
            return true
        end,
    },
})

vim.cmd.edit(main)
project = typst.project.set_main(main)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "preview should open with reuse=false"
)
assert(
    typst.viewer.preview({ mode = "slide" }) == true,
    "reuse=false should restart active previews"
)
assert(opened == 2, "reuse=false should call open for the replacement preview")
assert(
    stopped == 1,
    "reuse=false should stop the active preview before reopening"
)
assert(
    open_mode == "slide",
    "reuse=false should pass through the replacement mode"
)
assert(
    typst_test_preview(project).active == true,
    "reuse=false restart should leave the replacement preview active"
)

typst.reset({ force = true })
opened = 0
stopped = 0
open_mode = nil

local finish_stop = nil
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-controls-output"),
    preview = {
        open = function(_, opts)
            opened = opened + 1
            open_mode = opts.mode
            return true
        end,
        stop = function()
            stopped = stopped + 1
            return {
                pending = true,
                on_finish = function(callback)
                    finish_stop = callback
                end,
            }
        end,
    },
})

vim.cmd.edit(main)
project = typst.project.set_main(main)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "preview should open before async restart"
)
local restart_handle = typst.viewer.preview({ mode = "slide", restart = true })
assert(
    restart_handle and restart_handle.pending == true,
    "preview restart should return a pending restart handle"
)
assert(stopped == 1, "preview restart should start the async stop")
assert(opened == 1, "preview restart should wait for async stop before opening")
assert(
    typst_test_preview(project).stopping == true,
    "preview restart should mark the pending stop"
)
assert(
    type(finish_stop) == "function",
    "async stop should register finish hook"
)
finish_stop({ ok = true, stopped = true })
assert(opened == 2, "preview restart should reopen after async stop finishes")
assert(
    open_mode == "slide",
    "preview restart should preserve requested open options"
)
assert(
    restart_handle.pending == false,
    "preview restart handle should finish after reopening"
)
assert(
    typst_test_preview(project).active == true,
    "preview restart should leave the replacement preview active"
)
assert(
    typst_test_preview(project).stopping ~= true,
    "preview restart should clear stopping state after reopening"
)

typst.reset({ force = true })
opened = 0
stopped = 0
open_mode = nil

local finish_colon_stop = nil
local finish_colon_open = nil
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-controls-output"),
    preview = {
        open = function(_, opts)
            opened = opened + 1
            open_mode = opts.mode
            if opened == 1 then
                return true
            end

            local handle = {
                pending = true,
            }
            function handle:on_finish(callback)
                finish_colon_open = callback
                return self
            end
            return handle
        end,
        stop = function()
            stopped = stopped + 1
            local handle = {
                pending = true,
            }
            function handle:on_finish(callback)
                finish_colon_stop = callback
                return self
            end
            return handle
        end,
    },
})

vim.cmd.edit(main)
project = typst.project.set_main(main)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "method-style restart fixture should open first preview"
)
local colon_restart = typst.viewer.preview({ mode = "slide", restart = true })
assert(
    colon_restart and colon_restart.pending == true,
    "method-style preview restart should return a pending handle"
)
assert(
    type(finish_colon_stop) == "function",
    "method-style stop handle should receive finish subscription"
)
finish_colon_stop({ ok = true, stopped = true })
assert(opened == 2, "method-style restart should reopen after stop")
assert(
    open_mode == "slide",
    "method-style restart should preserve replacement mode"
)
assert(
    type(finish_colon_open) == "function",
    "method-style open handle should receive finish subscription"
)
assert(
    colon_restart.pending == true,
    "restart handle should wait for async replacement open"
)
finish_colon_open({ ok = true, opened = true })
assert(
    colon_restart.pending == false,
    "restart handle should finish after async replacement open"
)
assert(
    colon_restart.result and colon_restart.result.ok == true,
    "restart handle should keep replacement open result"
)

typst.reset({ force = true })
opened = 0
stopped = 0
local cancel_reason = nil
local finish_cancel_stop = nil

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-controls-output"),
    preview = {
        open = function()
            opened = opened + 1
            return true
        end,
        stop = function()
            stopped = stopped + 1
            return {
                pending = true,
                on_finish = function(callback)
                    finish_cancel_stop = callback
                end,
                cancel = function(_, opts)
                    cancel_reason = opts and opts.reason
                    return true,
                        {
                            ok = false,
                            reason = cancel_reason,
                            stopped = true,
                        }
                end,
            }
        end,
    },
})

vim.cmd.edit(main)
project = typst.project.set_main(main)
assert(typst.viewer.preview() == true, "preview should open before cancel test")
local cancel_handle = typst.viewer.preview({ restart = true })
assert(
    cancel_handle and cancel_handle.pending == true,
    "async preview restart should return a cancelable handle"
)
local cancelled = cancel_handle.cancel({ reason = "manual_cancel" })
assert(cancelled, "preview restart cancellation should report success")
assert(
    cancel_reason == "manual_cancel",
    "preview restart cancellation should pass cancel options"
)
assert(
    cancel_handle.pending == false,
    "preview restart cancellation should finish the restart handle"
)
assert(
    cancel_handle.result and cancel_handle.result.reason == "manual_cancel",
    "preview restart cancellation should retain terminal cancel result"
)
assert(
    type(finish_cancel_stop) == "function",
    "preview restart cancellation should keep the stop finish hook observable"
)
finish_cancel_stop({ ok = true, stopped = true })
assert(
    opened == 1,
    "preview stop completion after cancellation should not reopen preview"
)

vim.cmd("qa!")
