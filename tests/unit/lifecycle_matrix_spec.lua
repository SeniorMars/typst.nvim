local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local compiler = require("typst.compiler")
local lifecycle = require("typst.core.lifecycle")
local operations = require("typst.project.services.operations")
local project_services = require("typst.project.services")
local project_registry = require("typst.project")

local fixture_dir =
    typst_test_cache_path(("lifecycle-matrix-%d"):format(vim.uv.hrtime()))
vim.fn.mkdir(fixture_dir, "p")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("lifecycle-matrix-output"),
})

local function attach_project(name)
    local file = ("%s/%s.typ"):format(fixture_dir, name)
    vim.fn.writefile({ "= " .. name }, file)
    vim.cmd.edit(vim.fn.fnameescape(file))
    local bufnr = vim.api.nvim_get_current_buf()
    local project =
        assert(typst.project.set_main(file), "expected project attachment")
    return project, bufnr
end

for _, kind in ipairs({ "export", "render_image", "format" }) do
    local project, bufnr = attach_project("detach-" .. kind)
    local record =
        assert(operations.begin(project, kind), "operation record should start")
    assert(
        project_registry.all()[project.key] == project,
        "project should be registered before detach"
    )

    typst.project.detach(bufnr)
    assert(
        project_registry.all()[project.key] == project,
        "last-buffer detach should retain a project with active "
            .. kind
            .. " work"
    )

    operations.finish(project, record, { ok = true, kind = kind })
    assert(
        project_registry.all()[project.key] == nil,
        "finished detached "
            .. kind
            .. " work should allow empty project pruning"
    )
end

local orphan_project, orphan_bufnr = attach_project("reset-orphan")
local orphan_record = assert(
    operations.begin(orphan_project, "export"),
    "orphan operation record should start"
)
local cancel_calls = 0
local fake_operation = {
    state = "orphaned-running",
    wait = function(self)
        self.state = "orphaned-retained"
        self.orphaned = true
        self.retained = true
        self.orphan_retained = true
        self.result = {
            orphaned = true,
            retained = true,
            stopped = false,
        }
        return self
    end,
}
orphan_record.handle = {
    operation = fake_operation,
    cancel = function()
        cancel_calls = cancel_calls + 1
        return false, { orphaned = true, reason = "still_running" }
    end,
}

local reset_summary = typst.reset({
    operation_timeout_ms = 0,
    operation_kill_timeout_ms = 0,
    operation_wait_timeout_ms = 0,
    keep_telemetry = true,
})
assert(
    reset_summary and reset_summary.ok == false,
    "reset should report failure while an operation remains orphaned"
)
assert(cancel_calls == 1, "reset should attempt to cancel active operations")
assert(
    project_registry.all()[orphan_project.key] == orphan_project,
    "reset should retain projects while orphaned operations are retained"
)
assert(
    orphan_project.services.operations.active_by_id[orphan_record.id] == nil,
    "retained orphan operation should leave active records after reset"
)
assert(
    orphan_project.services.operations.retained_by_id[orphan_record.id]
        == orphan_record,
    "orphaned operation should remain visible as retained after reset"
)

operations.finish(orphan_project, orphan_record, {
    ok = false,
    was_orphaned = true,
    exited_after_orphan = true,
    stopped = false,
})
assert(
    orphan_project.services.operations.active_by_id[orphan_record.id] == nil,
    "late orphan exit should clear the active operation record"
)
assert(
    orphan_project.services.operations.retained_by_id[orphan_record.id] == nil,
    "late orphan exit should clear the retained operation record"
)

typst.project.detach(orphan_bufnr)
assert(
    project_registry.all()[orphan_project.key] == nil,
    "retained orphan project should prune after late exit and detach"
)

local stop_project, stop_bufnr = attach_project("stop-failure")
stop_project.bufs[stop_bufnr] = nil
typst_test_compiler(stop_project).process = {
    is_closing = function()
        return false
    end,
}

local original_compiler_stop = compiler.stop
compiler.stop = function(state, callback)
    callback({
        code = 1,
        stale = false,
        stopped = false,
        error = "simulated stop failure",
    })
    return state.process
end

local handled = lifecycle.stop_before_prune(
    stop_project,
    "stopping compiler in lifecycle failure test",
    "lifecycle failure test"
)

compiler.stop = original_compiler_stop

assert(handled, "lifecycle should handle active compiler cleanup")
assert(
    project_registry.all()[stop_project.key] == stop_project,
    "failed compiler stop should retain project ownership"
)
assert(
    typst_test_compiler(stop_project).status == "stopping_failed",
    "failed compiler stop should mark stopping_failed"
)

typst_test_compiler(stop_project).process = nil
typst_test_compiler(stop_project).status = "idle"
project_registry.prune(stop_project, "test cleanup")

typst.reset({ force = true })

local stop_started = false
local stop_callback_registry_count = nil
local provider = {
    name = "reset-transaction-provider",
    compile = function()
        return {
            kind = "compile",
        }
    end,
    start = function()
        return {
            kind = "watch",
        }
    end,
    stop = function(_project, callback)
        stop_started = true
        vim.defer_fn(function()
            stop_callback_registry_count = vim.tbl_count(project_registry.all())
            callback({ code = 0, stale = false, stopped = true })
        end, 25)
        return {
            kind = "stop",
        }
    end,
    status = function(project)
        return typst_test_compiler(project).status
    end,
    output = function(project)
        return typst_test_cache_path("reset-transaction/main.pdf")
    end,
}

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("reset-transaction-output"),
    compile = {
        provider = provider,
    },
})

local reset_main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(reset_main)
local reset_project = typst.project.set_main(reset_main)
typst.compiler.compile({ notify = false })
assert(
    typst_test_compiler(reset_project).process,
    "reset transaction fixture should have an active custom compile"
)

typst.reset()

assert(
    stop_started,
    "typst.reset should request provider stop before clearing projects"
)
assert(
    stop_callback_registry_count and stop_callback_registry_count > 0,
    "typst.reset should wait for async stop callback before clearing registry"
)
assert(
    vim.tbl_count(project_registry.all()) == 0,
    "typst.reset should clear registry after active stops finish"
)
assert(
    typst_test_compiler(reset_project).process == nil
        and typst_test_compiler(reset_project).status == "idle",
    "typst.reset should leave stopped projects idle"
)

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("vimleave-operations-output"),
    compile = {
        deps = false,
    },
})

local exit_main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(exit_main)
local exit_project = typst.project.set_main(exit_main)
exit_project = assert(typst.project.attach(0), "project should attach")

local cancel_opts = nil
local exit_record = operations.begin(exit_project, "render_fragment")
exit_record.handle = {
    cancel = function(self_or_opts, maybe_opts)
        cancel_opts = maybe_opts or self_or_opts
        return true, { stopped = true, reason = cancel_opts.reason }
    end,
}

vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })

assert(
    cancel_opts and cancel_opts.reason == "exit",
    "exit should cancel operations"
)
assert(
    not project_services.operations(exit_project).active_by_id[exit_record.id],
    "exit-cancelled operation should be removed from active records"
)

vim.cmd("qa!")
