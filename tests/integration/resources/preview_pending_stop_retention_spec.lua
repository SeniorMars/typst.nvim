local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_store = require("typst.project.store")
local typst = require("typst")

typst.reset({ force = true })

local stop_calls = 0

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("resource-preview-pending-stop-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            stop_calls = stop_calls + 1
            return {
                pending = true,
                on_finish_style = "colon",
                on_finish = function()
                    return nil
                end,
            }
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
project = require("typst.project.context").live(project) or project

assert(typst.viewer.preview() == true, "preview should open")

local summary = typst.reset({ reason = "preview-pending-stop-test" })
assert(summary and summary.ok == false, "reset should report pending stop")
assert(
    summary.retained_projects == true,
    "reset should retain projects with pending preview stop"
)
assert(stop_calls == 1, "reset should attempt preview stop once")
assert(
    project_store.all()[project.key] == project,
    "pending preview stop should keep project visible for recovery"
)
assert(
    typst_test_preview(project).active == true,
    "pending preview stop should preserve active preview state"
)
assert(
    typst_test_preview(project).stopping == true,
    "pending preview stop should mark stopping"
)

local saw_preview_blocker = false
for _, blocker in ipairs(summary.blockers or {}) do
    saw_preview_blocker = saw_preview_blocker
        or blocker.kind == "preview_stop_unconfirmed"
        or blocker.kind == "preview_stop_pending"
end
for _, failure in ipairs(summary.failed or {}) do
    saw_preview_blocker = saw_preview_blocker
        or failure.reason == "preview_stop_pending"
end
assert(
    saw_preview_blocker,
    "reset summary should expose preview pending-stop blocker"
)

local force_summary =
    typst.reset({ force = true, reason = "preview-force-reset-test" })
assert(
    force_summary and force_summary.retained_projects == false,
    "force reset should not retain projects after forced preview cleanup"
)
assert(
    project_store.all()[project.key] == nil,
    "force reset should clear retained preview project state"
)
for _, blocker in ipairs(force_summary.blockers or {}) do
    assert(
        blocker.project_key ~= project.key,
        "force reset final snapshot should not keep blockers for cleared project"
    )
end

vim.cmd("qa!")
