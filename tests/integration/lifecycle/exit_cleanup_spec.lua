local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local registry = require("typst.project")
local project_store = require("typst.project.store")
local typst = require("typst")
typst.reset()

local executable = helpers.fake_typst_sleep(root)
local preview_stopped = 0
local preview_stop_project = nil

typst.setup({
    root = root,
    executable = executable,
    output_dir = typst_test_cache_path("exit-cleanup-output"),
    compile = {
        deps = false,
    },
    preview = {
        open = function()
            return true
        end,
        stop = function(project)
            preview_stopped = preview_stopped + 1
            preview_stop_project = project
            return true
        end,
    },
})

local quit_event = nil
local stopped_events = {}
local preview_stopped_event = nil

vim.api.nvim_create_autocmd("User", {
    pattern = "TypstEventQuit",
    callback = function(args)
        quit_event = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompileStopped",
    callback = function(args)
        stopped_events[#stopped_events + 1] = args.data
    end,
})
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewStopped",
    callback = function(args)
        preview_stopped_event = args.data
    end,
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local compile_project = typst.project.set_main(main)
local compile_handle = typst.compiler.compile({}, function()
    error("exit cleanup should stale active compile callbacks")
end)

assert(
    typst_test_compiler(compile_project).process == compile_handle,
    "compile should be active before VimLeavePre cleanup"
)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "preview should open before VimLeavePre cleanup"
)
assert(
    typst_test_preview(compile_project).active == true,
    "preview should be active before VimLeavePre cleanup"
)

local chapter = root .. "/tests/fixtures/basic/chapter.typ"
vim.cmd.edit(chapter)
local watch_project = typst.project.set_main(chapter)
assert(
    watch_project.key ~= compile_project.key,
    "exit cleanup fixture should use two projects"
)
local watch_handle = typst.compiler.watch()

assert(
    typst_test_compiler(watch_project).watcher
        and typst_test_compiler(watch_project).watcher.handle
            == watch_handle,
    "watcher should be active before cleanup"
)
assert(
    vim.tbl_count(project_store.all()) >= 2,
    "exit cleanup should see both registered projects"
)

vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })

assert(
    quit_event and quit_event.projects >= 2,
    "VimLeavePre should emit a quit event with project count"
)
assert(
    typst_test_compiler(compile_project).process == nil,
    "VimLeavePre should clear active one-shot compile handles"
)
assert(
    typst_test_compiler(compile_project).status == "idle",
    "VimLeavePre should return stopped compile projects to idle"
)
assert(preview_stopped == 1, "VimLeavePre should stop active previews")
assert(
    preview_stop_project and preview_stop_project.key == compile_project.key,
    "preview stop should receive the project"
)
assert(
    typst_test_preview(compile_project).active == false,
    "VimLeavePre should clear preview_active"
)
assert(
    preview_stopped_event and preview_stopped_event.key == compile_project.key,
    "preview stopped event should be emitted"
)
assert(
    compile_handle:is_closing(),
    "VimLeavePre should wait for active compile handles to close"
)
assert(
    watch_handle:is_closing(),
    "VimLeavePre should wait for active watcher handles to close"
)
assert(
    typst_test_compiler(watch_project).watcher == nil,
    "VimLeavePre should clear active watcher handles before returning"
)
assert(
    #stopped_events >= 2,
    "VimLeavePre should emit stopped events after bounded shutdown"
)

assert(
    vim.wait(10000, function()
        return compile_handle:is_closing()
            and watch_handle:is_closing()
            and typst_test_compiler(watch_project).watcher == nil
            and #stopped_events >= 2
    end, 20),
    "VimLeavePre should terminate active compile and watcher processes"
)

assert(
    typst_test_compiler(watch_project).status == "idle",
    "VimLeavePre should return stopped watcher projects to idle"
)

typst.reset()

local pending_stop_called = 0
local pending_stop_handle = nil
typst.setup({
    root = root,
    executable = executable,
    output_dir = typst_test_cache_path("exit-cleanup-pending-preview"),
    compile = {
        deps = false,
    },
    preview = {
        open = function()
            return true
        end,
        stop = function()
            pending_stop_called = pending_stop_called + 1
            pending_stop_handle = {
                pending = true,
                on_finish_style = "colon",
            }
            function pending_stop_handle:on_finish(callback)
                self.callback = callback
                return self
            end
            return pending_stop_handle
        end,
    },
})

vim.cmd.edit(main)
local pending_project = typst.project.set_main(main)
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "pending-stop preview should open before VimLeavePre cleanup"
)
assert(
    typst_test_preview(pending_project).active == true,
    "pending-stop preview should be active before VimLeavePre cleanup"
)

vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })

assert(pending_stop_called == 1, "VimLeavePre should request preview stop")
assert(
    pending_stop_handle and pending_stop_handle.pending == true,
    "preview stop fixture should return a pending handle"
)
assert(
    typst_test_preview(pending_project).active == true,
    "pending preview stop should not clear active state during exit"
)
assert(
    typst_test_preview(pending_project).status == "stopping_failed",
    "pending preview stop should be recorded as unconfirmed during exit"
)
assert(
    typst_test_preview(pending_project).stopping == true,
    "pending preview stop should record stopping=true during exit"
)
assert(
    typst_test_preview(pending_project).last_error == "pending",
    "pending preview stop should record a last_error during exit"
)

vim.cmd("qa!")
