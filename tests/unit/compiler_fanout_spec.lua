local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local saved = {}
local stubbed_modules = {}
local function stub(module, value)
    saved[module] = package.loaded[module]
    stubbed_modules[#stubbed_modules + 1] = module
    package.loaded[module] = value
end

local calls = {}

stub("typst.compiler.fanout", nil)
stub("typst.compiler.dependencies", {
    take = function(path, project_root)
        calls.take = { path = path, root = project_root }
        return { [path] = true }
    end,
    update_project = function(project, deps)
        calls.update_project = { project = project, deps = deps }
    end,
    cleanup_file = function(path)
        calls.cleanup_file = path
    end,
    refresh_watcher = function()
        calls.refresh_watcher = (calls.refresh_watcher or 0) + 1
    end,
})
stub("typst.compiler.events", {
    succeeded = function()
        calls.succeeded = (calls.succeeded or 0) + 1
    end,
    failed = function()
        calls.failed = (calls.failed or 0) + 1
    end,
    cycle_started = function()
        calls.cycle_started = (calls.cycle_started or 0) + 1
    end,
    cycle_succeeded = function()
        calls.cycle_succeeded = (calls.cycle_succeeded or 0) + 1
    end,
    cycle_failed = function()
        calls.cycle_failed = (calls.cycle_failed or 0) + 1
    end,
})
stub("typst.core.log", {
    add = function()
        calls.log = (calls.log or 0) + 1
    end,
})
stub("typst.diagnostics", {
    should_publish = function()
        calls.should_publish = (calls.should_publish or 0) + 1
        return true
    end,
    publish = function()
        calls.publish = (calls.publish or 0) + 1
    end,
    clear = function()
        calls.clear = (calls.clear or 0) + 1
    end,
})
stub("typst.workflows.artifacts", {
    record_owned = function(project, opts)
        calls.record_owned = { project = project, opts = opts }
    end,
})

local ok, err = xpcall(function()
    local fanout = require("typst.compiler.fanout")
    local project = {
        key = "fanout-project",
        root = root,
        main = root .. "/tests/fixtures/basic/main.typ",
    }

    fanout.watch_cycle_failed(project, {
        stderr = "hidden",
    }, {
        publish_diagnostics = false,
        log = false,
        emit = false,
    })
    assert(
        not calls.should_publish and not calls.publish and not calls.clear,
        "watch_cycle_failed should honor publish_diagnostics=false"
    )
    assert(not calls.cycle_failed, "watch_cycle_failed should honor emit=false")

    fanout.watch_cycle_started(project, {
        cycle = 2,
    }, {
        publish_diagnostics = false,
        log = false,
        emit = false,
    })
    assert(
        not calls.cycle_started,
        "watch_cycle_started should honor emit=false"
    )

    fanout.compile_succeeded(project, {
        deps_path = "result-deps.json",
    }, {
        deps_path = "opts-deps.json",
        output = root .. "/tests/.tmp/fanout.pdf",
        generation = 7,
    })
    assert(
        calls.take
            and calls.take.path == "opts-deps.json"
            and calls.take.root == root,
        "compile_succeeded should prefer opts.deps_path"
    )
    assert(
        calls.update_project and calls.update_project.deps["opts-deps.json"],
        "compile_succeeded should update dependencies from opts.deps_path"
    )

    fanout.compile_failed(project, {
        deps_path = "result-fail-deps.json",
    }, {
        deps_path = "opts-fail-deps.json",
        publish_diagnostics = false,
    })
    assert(
        calls.cleanup_file == "opts-fail-deps.json",
        "compile_failed should prefer opts.deps_path for cleanup"
    )

    local failed_before = calls.failed or 0
    local log_before = calls.log or 0
    fanout.compile_failed(project, {
        stderr = "quiet compile failure",
    }, {
        publish_diagnostics = false,
        cleanup_deps = false,
        log = false,
        emit = false,
    })
    assert(
        (calls.failed or 0) == failed_before,
        "compile_failed should honor emit=false"
    )
    assert(
        (calls.log or 0) == log_before,
        "compile_failed should honor log=false"
    )

    local cleanup_before = calls.cleanup_file
    fanout.watch_failed(
        project,
        {
            stderr = "quiet watch failure",
        },
        "quiet-watch-deps.json",
        {
            publish_diagnostics = false,
            log = false,
            emit = false,
        }
    )
    assert(
        calls.cleanup_file == "quiet-watch-deps.json"
            and calls.cleanup_file ~= cleanup_before,
        "watch_failed should clean the requested deps file"
    )
    assert(
        (calls.failed or 0) == failed_before,
        "watch_failed should honor emit=false"
    )
    assert(
        (calls.log or 0) == log_before,
        "watch_failed should honor log=false"
    )
end, debug.traceback)

for _, module in ipairs(stubbed_modules) do
    package.loaded[module] = saved[module]
end
package.loaded["typst.compiler.fanout"] = saved["typst.compiler.fanout"]

if not ok then
    error(err)
end

vim.cmd("qa!")
