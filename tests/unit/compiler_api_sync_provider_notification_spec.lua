local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local saved = {}
local stubbed = {}

local function stub(module, value)
    saved[module] = package.loaded[module]
    stubbed[#stubbed + 1] = module
    package.loaded[module] = value
end

local compile_return
local compile_result
local start_return
local start_result

stub("typst.compiler.api", nil)
stub("typst.compiler", {
    compile = function(_state, callback)
        if compile_result then
            callback(compile_result)
        end
        return compile_return
    end,
    start = function(_state, callback)
        if start_result then
            callback(start_result)
        end
        return start_return
    end,
})
stub("typst.config", {
    unsafe_get = function()
        return { project = {} }
    end,
    for_run = function()
        return { compile = { open = false, profile = nil } }
    end,
})
stub("typst.compiler.consumers", {
    after_compile = function() end,
    after_watch_cycle = function()
        return {}
    end,
})
stub("typst.compiler.fragments", {})
stub("typst.project.services.compiler", {
    get = function()
        return { output = root .. "/out.pdf" }
    end,
})
stub("typst.core.log", { add = function() end })
stub("typst.project", {})
stub("typst.project.store", {})
stub("typst.ui.reports", {})
stub("typst.core.util", {
    relpath = function(path)
        return path
    end,
})
local ok, err = xpcall(function()
    local api = require("typst.compiler.api")
    local project = {
        root = root,
        main = root .. "/main.typ",
    }

    local messages = {}
    local function notify(message)
        messages[#messages + 1] = message
    end

    compile_result = { code = 0 }
    compile_return = { ok = true, code = 0 }
    api.compile(project, {}, nil, notify)
    assert(
        not vim.tbl_contains(messages, "Compiling " .. project.main),
        "sync compile success should not emit a late Compiling notification"
    )

    messages = {}
    compile_result = { code = 1 }
    compile_return = { ok = false, code = 1, reason = "failed" }
    api.compile(project, {}, nil, notify)
    for _, message in ipairs(messages) do
        assert(
            not message:match("^Compiling "),
            "sync compile failure should not emit Compiling"
        )
    end

    messages = {}
    compile_result = nil
    compile_return = { pending = true }
    api.compile(project, {}, nil, notify)
    assert(
        messages[1] == "Compiling " .. project.main,
        "pending compile handles should still emit Compiling"
    )

    messages = {}
    compile_result = nil
    compile_return = false
    api.compile(project, {}, nil, notify)
    for _, message in ipairs(messages) do
        assert(
            not message:match("^Compiling "),
            "false compile handles should not emit Compiling"
        )
    end

    messages = {}
    start_result = { code = 1 }
    start_return = { ok = false, code = 1, reason = "failed" }
    api.watch(project, {}, nil, notify)
    for _, message in ipairs(messages) do
        assert(
            not message:match("^Watching "),
            "sync watch failure should not emit Watching"
        )
    end

    messages = {}
    start_result = nil
    start_return = { pending = true }
    api.watch(project, {}, nil, notify)
    assert(
        messages[1] == "Watching " .. project.main,
        "pending watch handles should still emit Watching"
    )

    messages = {}
    start_result = nil
    start_return = false
    api.watch(project, {}, nil, notify)
    for _, message in ipairs(messages) do
        assert(
            not message:match("^Watching "),
            "false watch handles should not emit Watching"
        )
    end
end, debug.traceback)

for _, module in ipairs(stubbed) do
    package.loaded[module] = saved[module]
end

if not ok then
    error(err)
end

vim.cmd("qa!")
