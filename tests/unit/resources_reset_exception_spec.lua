local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_store = require("typst.project.store")
local supervisor = require("typst.resources.supervisor")
local core_lifecycle = require("typst.core.lifecycle")

project_store.reset()

local project_a =
    assert(project_store.create(root, root .. "/tests/fixtures/basic/main.typ"))
local project_b = assert(
    project_store.create(root, root .. "/tests/fixtures/basic/other.typ")
)

local bufnr_a = vim.api.nvim_create_buf(false, true)
local bufnr_b = vim.api.nvim_create_buf(false, true)
local orphan_bufnr = vim.api.nvim_create_buf(false, true)

project_a.bufs[bufnr_a] = true
project_b.bufs[bufnr_b] = true
project_store.set_buffer(bufnr_a, project_a.key)
project_store.set_buffer(bufnr_b, project_b.key)

local original_clear_buffer = core_lifecycle.clear_buffer
local clear_calls = {}
local injected = false
local final_injected = false
rawset(core_lifecycle, "clear_buffer", function(bufnr)
    clear_calls[#clear_calls + 1] = bufnr
    if bufnr == bufnr_a and not injected then
        injected = true
        error("injected reset failure")
    end
    if bufnr == orphan_bufnr and not final_injected then
        final_injected = true
        error("injected final buffer reset failure")
    end
    return original_clear_buffer(bufnr)
end)

local ok, summary = xpcall(function()
    return supervisor.reset({ force = true })
end, debug.traceback)

rawset(core_lifecycle, "clear_buffer", original_clear_buffer)

if not ok then
    error(summary)
end

assert(injected, "reset test should inject a project-local failure")
assert(final_injected, "reset test should inject a final buffer failure")
assert(summary.ok == false, "reset should report injected project failure")

local saw_project_exception = false
local saw_buffer_clear_failure = false
for _, failure in ipairs(summary.failed or {}) do
    if failure.reason == "project_reset_exception" then
        saw_project_exception = true
    end
    if
        failure.reason == "buffer_clear_failed"
        and failure.bufnr == orphan_bufnr
    then
        saw_buffer_clear_failure = true
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
    vim.tbl_contains(clear_calls, bufnr_b),
    "reset should continue to later projects after one project fails"
)
assert(
    saw_buffer_clear_failure,
    "reset should summarize final buffer cleanup exceptions"
)

project_store.reset()
vim.api.nvim_buf_delete(bufnr_a, { force = true })
vim.api.nvim_buf_delete(bufnr_b, { force = true })
vim.api.nvim_buf_delete(orphan_bufnr, { force = true })

vim.cmd("qa!")
