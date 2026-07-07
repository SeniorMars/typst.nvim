local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_context = require("typst.project.context")
local resource_session = require("typst.resources.session")
local typst = require("typst")

local function setup_project(open_callback)
    typst.reset({ force = true })
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("preview-pending-cancel-output"),
        preview = {
            open = open_callback,
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    return project_context.live(project) or project
end

local function has_blocker(project, kind)
    for _, blocker in ipairs(resource_session.blockers(project)) do
        if blocker.kind == kind then
            return true
        end
    end
    return false
end

local cancel_calls = 0
local finish_cancel = nil
local project = setup_project(function()
    local handle = {
        pending = true,
        on_finish_style = "colon",
        cancel_style = "colon",
    }
    function handle:on_finish()
        return self
    end
    function handle:cancel()
        cancel_calls = cancel_calls + 1
        local cancel_handle = {
            pending = true,
            on_finish_style = "colon",
        }
        function cancel_handle:on_finish(callback)
            finish_cancel = callback
            return self
        end
        return false, cancel_handle
    end
    return handle
end)

local pending = typst.viewer.preview()
assert(pending and pending.pending == true, "preview open should be pending")
local snapshot = resource_session.snapshot(project)
assert(
    snapshot.preview.opening == true,
    "resource snapshot should report pending preview open"
)
assert(
    resource_session.has_active(project) == true,
    "pending preview open should count as an active resource"
)
assert(
    has_blocker(project, "preview_opening"),
    "pending preview open should be visible as a blocker"
)
local cancelled = typst.viewer.preview_stop({ reason = "user" })
assert(
    cancelled and cancelled.cancel_pending == true,
    "pending cancel should report pending cancellation"
)
assert(cancel_calls == 1, "provider cancel should be called once")
assert(
    typst_test_preview(project).opening == true,
    "pending cancel should retain pending-open ownership until confirmed"
)
assert(
    typst_test_preview(project).status == "open_cancel_pending",
    "pending cancel should record open_cancel_pending status"
)

assert(type(finish_cancel) == "function", "cancel result should be observed")
finish_cancel({
    ok = true,
    stopped = true,
})
assert(pending.pending == false, "confirmed cancel should finish open handle")
assert(
    typst_test_preview(project).opening == false,
    "confirmed cancel should clear opening state"
)
assert(
    typst_test_preview(project).active == false,
    "confirmed cancel should leave preview inactive"
)
assert(
    resource_session.has_active(project) == false,
    "confirmed pending-open cancel should clear resource activity"
)

typst.reset({ force = true })
vim.cmd("qa!")
