local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_store = require("typst.project.store")
local resource_manager = require("typst.runtime.resource_manager")

project_store.reset()

local project_a =
    assert(project_store.create(root, root .. "/tests/fixtures/basic/main.typ"))
local project_b = assert(
    project_store.create(root, root .. "/tests/fixtures/basic/other.typ")
)

local bufnr_a = vim.api.nvim_create_buf(false, true)
local bufnr_b = vim.api.nvim_create_buf(false, true)

project_a.bufs[bufnr_a] = true
project_b.bufs[bufnr_b] = true
project_store.set_buffer(bufnr_a, project_a.key)
project_store.set_buffer(bufnr_b, project_b.key)

local original_preview = package.loaded["typst.resources.drivers.preview"]
    or require("typst.resources.drivers.preview")
local original_core_buffer = package.loaded["typst.core.buffer"]
    or require("typst.core.buffer")
local preview_injected = false
local buffer_injected = false
package.loaded["typst.resources.drivers.preview"] = {
    stop_project = function(_, project)
        if project == project_a and not preview_injected then
            preview_injected = true
            error("injected reset failure")
        end
        return { ok = true }
    end,
}
package.loaded["typst.core.buffer"] = vim.tbl_extend("force", original_core_buffer, {
    reset = function()
        if not buffer_injected then
            buffer_injected = true
            error("injected editor reset failure")
        end
        return original_core_buffer.reset()
    end,
})

local ok, summary = xpcall(function()
    return resource_manager.reset({ force = true })
end, debug.traceback)

package.loaded["typst.resources.drivers.preview"] = original_preview
package.loaded["typst.core.buffer"] = original_core_buffer

if not ok then
    error(summary)
end

assert(preview_injected, "reset test should inject a project-local failure")
assert(buffer_injected, "reset test should inject an editor-state failure")
assert(summary.ok == false, "reset should report injected project failure")

local saw_project_exception = false
local saw_buffer_reset_failure = false
for _, failure in ipairs(summary.failed or {}) do
    if failure.reason == "project_reset_exception" then
        saw_project_exception = true
    end
end
for _, failure in ipairs(summary.phase_failures or {}) do
    if failure.entry == "core.buffer" and failure.reason == "error" then
        saw_buffer_reset_failure = true
    end
end
assert(
    saw_project_exception,
    "reset should summarize per-project reset exceptions"
)
assert(
    project_a.resetting == false and project_b.resetting == false,
    "reset should clear resetting flag even when a project reset throws"
)
assert(
    saw_buffer_reset_failure,
    "reset should summarize editor-state cleanup exceptions"
)

project_store.reset()
vim.api.nvim_buf_delete(bufnr_a, { force = true })
vim.api.nvim_buf_delete(bufnr_b, { force = true })

vim.cmd("qa!")
