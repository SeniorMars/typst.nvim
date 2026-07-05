local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local render = require("typst.workflows.render")

local provider_callbacks = {}
local results = {}

typst.reset()
local generation_root = typst_test_cache_path("render-generation-project")
vim.fn.mkdir(generation_root, "p")
local generation_main = generation_root .. "/main.typ"
vim.fn.writefile({ "= Render Generation", "body" }, generation_main)
typst.setup({
    root = generation_root,
    render = {
        output_dir = typst_test_cache_path("render-generation-output"),
        source_mode = "file",
        source_dir = generation_root .. "/render-generation-sources",
        provider = function(_, _, callback)
            provider_callbacks[#provider_callbacks + 1] = callback
            return { pending = true }
        end,
    },
})
vim.cmd.edit(generation_main)
vim.bo.filetype = "typst"
local project = typst.project.attach(0)

render.fragment(project, { source = "older" }, function(result)
    results[#results + 1] = result
end, function() end)
render.fragment(project, { source = "newer" }, function(result)
    results[#results + 1] = result
end, function() end)
provider_callbacks[2]({
    ok = true,
    path = generation_main,
    format = "typ",
})
provider_callbacks[1]({
    ok = true,
    path = generation_main,
    format = "typ",
})
assert(results[1] and results[1].ok, "newer render should complete")
assert(results[2] and results[2].stale, "older render should be stale")
assert(
    results[2].reason == "stale_result",
    "older render should report stale_result"
)

typst.reset()
local cancel_root = typst_test_cache_path("render-cancel-project")
vim.fn.mkdir(cancel_root, "p")
local cancel_main = cancel_root .. "/main.typ"
vim.fn.writefile({ "= Render Cancel", "body" }, cancel_main)
typst.setup({
    root = cancel_root,
    executable = { "sh", "-c", "sleep 2", "sh" },
    output_dir = typst_test_cache_path("render-cancel-output"),
    render = {
        output_dir = typst_test_cache_path("render-cancel-cache"),
        source_mode = "file",
        source_dir = cancel_root .. "/render-cancel-sources",
        output_format = "svg",
    },
})
vim.cmd.edit(cancel_main)
project = typst.project.set_main(cancel_main)
typst.render.cache_clear({ force = true })
local cancel_result = render.equation(
    project,
    { expression = "alpha", open = false },
    function() end,
    function() end
)

assert(cancel_result.pending == true, "slow render should start as pending")
assert(
    cancel_result.source_path
        and vim.fn.filereadable(cancel_result.source_path) == 1,
    "render source should exist while the render is pending"
)

cancel_result.cancel({
    reason = "test_cancel",
    timeout_ms = 50,
    kill_timeout_ms = 50,
})
assert(
    vim.wait(3000, function()
        return cancel_result.pending == false
    end, 20),
    "cancelled render did not finish"
)
assert(cancel_result.cancelled == true, "render should be marked cancelled")
assert(
    vim.fn.filereadable(cancel_result.source_path) == 0,
    "cancelled render should remove its temporary source"
)
assert(
    not cancel_result.path or vim.fn.filereadable(cancel_result.path) == 0,
    "cancelled render should not leave an unremembered output file"
)

typst.reset()
local failure_root = typst_test_cache_path("render-failure-project")
vim.fn.mkdir(failure_root, "p")
local failure_main = failure_root .. "/main.typ"
vim.fn.writefile({ "= Render Failure", "body" }, failure_main)
typst.setup({
    root = failure_root,
    executable = { "sh", "-c", "sleep 0.2; exit 1", "sh" },
    output_dir = typst_test_cache_path("render-failure-output"),
    render = {
        output_dir = typst_test_cache_path("render-failure-cache"),
        source_mode = "file",
        source_dir = failure_root .. "/render-failure-sources",
        output_format = "svg",
    },
})
vim.cmd.edit(failure_main)
project = typst.project.set_main(failure_main)
typst.render.cache_clear({ force = true })
---@type any
local failure_result = nil
local failed_run = render.equation(
    project,
    { expression = "beta", open = false },
    function(result)
        failure_result = result
    end,
    function() end
)

assert(failed_run.pending == true, "failing render should start as pending")
assert(
    failed_run.source_path and vim.fn.filereadable(failed_run.source_path) == 1,
    "failing render source should exist while the render is pending"
)
assert(
    vim.wait(3000, function()
        return failure_result ~= nil
    end, 20),
    "failing render did not finish"
)
assert(failure_result.ok == false, "failing render should report failure")
assert(
    vim.fn.filereadable(failed_run.source_path) == 0,
    "failed render should remove its temporary source"
)

vim.cmd("qa!")
