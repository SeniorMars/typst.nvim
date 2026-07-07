local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local preview_service = require("typst.project.services.preview")
local preview_status = require("typst.preview.status")
local resource_manager = require("typst.runtime.resource_manager")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    completion = {
        package_cache_prewarm = false,
    },
})

local project_root = typst_test_cache_path("preview-status-service-compat")
vim.fn.delete(project_root, "rf")
vim.fn.mkdir(project_root, "p")
local main = project_root .. "/main.typ"
vim.fn.writefile({ "= Preview Status" }, main)

vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
local project = assert(typst.project.set_main(main))
preview_service.set(project, {
    active = true,
    active_backend = "callback",
    active_output = project_root .. "/main.pdf",
})

local original_snapshot = preview_service.snapshot
rawset(preview_service, "snapshot", nil)
local fallback = preview_status.snapshot(project, { cache = false })
assert(
    fallback.ok == true
        and fallback.active == true
        and fallback.backend == "callback",
    "preview status should fall back to preview_service.get when snapshot is absent"
)
rawset(preview_service, "snapshot", function()
    error("synthetic snapshot failure")
end)
local failed_snapshot = preview_status.snapshot(project, { cache = false })
assert(
    failed_snapshot.ok == true and failed_snapshot.active == true,
    "preview status should recover from preview_service.snapshot failures"
)
local resources = resource_manager.snapshot(project)
assert(
    type(resources) == "table",
    "resource manager snapshot should not throw when preview snapshot fails"
)

rawset(preview_service, "snapshot", original_snapshot)
typst.reset({ force = true })

vim.cmd("qa!")
