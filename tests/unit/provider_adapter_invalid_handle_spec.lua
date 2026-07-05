local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local project_store = require("typst.project.store")

local callback_result = nil
local started_saw_process = nil
local started_saw_watcher = nil

local provider = {
    name = "invalid-handle-provider",
    compile = function()
        return "bad-compile-handle"
    end,
    start = function()
        return 42
    end,
    stop = function(_project, callback)
        if callback then
            callback({ code = 0, stopped = true, stale = false })
        end
        return nil
    end,
    output = function()
        return typst_test_cache_path("invalid-handle-provider/output.pdf")
    end,
    status = function(project)
        return "invalid-handle-" .. typst_test_compiler(project).status
    end,
}

typst.reset({ force = true })
typst.setup({
    root = root,
    compile = {
        provider = provider,
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(vim.fn.fnameescape(main))
local project = assert(typst.project.set_main(main))
local live_project = assert(project_store.get(project.key))

vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompileStarted",
    callback = function()
        started_saw_process = typst_test_compiler(project).process ~= nil
        started_saw_watcher = typst_test_compiler(project).watcher ~= nil
    end,
})
local compile_result = typst.compiler.compile({}, function(result)
    callback_result = result
end)
assert(
    compile_result
        and compile_result.reason == "invalid_result"
        and compile_result.provider == "invalid-handle-provider",
    "invalid compiler provider handles should become terminal invalid results"
)
assert(
    callback_result == compile_result,
    "invalid compiler handle should be returned through the callback"
)
assert(
    typst_test_compiler(project).process == nil,
    "invalid compiler handle should never be installed as active process"
)
assert(
    typst_test_compiler(project).output_lease == nil,
    "invalid compiler handle should release output ownership"
)
assert(
    started_saw_process == false,
    "started event should not expose invalid compile handles as active"
)

callback_result = nil
local watch_result = typst.compiler.watch({}, function(result)
    callback_result = result
end)
assert(
    watch_result
        and watch_result.reason == "invalid_result"
        and watch_result.provider == "invalid-handle-provider",
    "invalid watcher provider handles should become terminal invalid results"
)
assert(
    callback_result == watch_result,
    "invalid watcher handle should be returned through the callback"
)
assert(
    typst_test_compiler(project).watcher == nil,
    "invalid watcher handle should never be installed as active watcher"
)
assert(
    typst_test_compiler(project).output_lease == nil,
    "invalid watcher handle should release output ownership"
)
assert(
    started_saw_watcher == false,
    "started event should not expose invalid watcher handles as active"
)
assert(
    project_store.all()[project.key] == live_project,
    "invalid handle failures should not corrupt project registration"
)

typst.reset({ force = true })
vim.cmd("qa!")
