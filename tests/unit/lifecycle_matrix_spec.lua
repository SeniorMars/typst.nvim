local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local compiler = require("typst.compiler")
local debug_tools = require("typst.internal.debug")
local lifecycle = require("typst.core.lifecycle")
local operations = require("typst.project.services.operations")
local output_ownership = require("typst.resources.outputs")
local preview_service = require("typst.project.services.preview")
local project_services = require("typst.project.services")
local project_registry = require("typst.project")
local project_store = require("typst.project.store")
local resource_manager = require("typst.runtime.resource_manager")

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
    local snapshot =
        assert(typst.project.set_main(file), "expected project attachment")
    local project = assert(project_store.get(snapshot.key))
    return project, bufnr
end

local function pending_stop_handle()
    local handle = {
        pending = true,
        on_finish_style = "colon",
    }
    function handle:on_finish(callback)
        self.callback = callback
        return self
    end
    return handle
end

local function record_active_preview(project, backend, command)
    preview_service.set(project, {
        active = true,
        active_backend = backend,
        active_command = command,
        active_cwd = root,
        last_backend = backend,
        last_command = command and vim.deepcopy(command) or nil,
        last_cwd = root,
    })
end

for _, kind in ipairs({ "export", "render_image", "format" }) do
    local project, bufnr = attach_project("detach-" .. kind)
    local record =
        assert(operations.begin(project, kind), "operation record should start")
    assert(
        project_store.all()[project.key] == project,
        "project should be registered before detach"
    )

    typst.project.detach(bufnr)
    assert(
        project_store.all()[project.key] == project,
        "last-buffer detach should retain a project with active "
            .. kind
            .. " work"
    )
    assert(
        resource_manager.stop_before_prune(project, {
            log_message = "checking active operation retention in lifecycle matrix test",
            reason = "active operation retention",
        }) == true,
        "runtime.resource_manager should report active operation retention"
    )

    operations.finish(project, record, { ok = true, kind = kind })
    assert(
        project_store.all()[project.key] == nil,
        "finished detached "
            .. kind
            .. " work should allow empty project pruning"
    )
end

local lease_project, lease_bufnr = attach_project("detach-output-lease")
local lease = assert(
    output_ownership.acquire(
        typst_test_cache_path("lifecycle-matrix-output/detach-output-lease.pdf"),
        output_ownership.owner("unit-test", lease_project)
    )
)
typst.project.detach(lease_bufnr)
assert(
    project_store.all()[lease_project.key] == lease_project,
    "last-buffer detach should retain a project with an active output lease"
)
assert(
    resource_manager.stop_before_prune(lease_project, {
        log_message = "checking active output lease retention in lifecycle matrix test",
        reason = "active output lease retention",
    }) == true,
    "runtime.resource_manager should report active output lease retention"
)
local invariant_result = debug_tools.check_invariants()
for _, finding in ipairs(invariant_result.findings or {}) do
    assert(
        finding.code ~= "lease_unknown_project",
        "detached project with active lease should stay registered"
    )
end
assert(
    output_ownership.release(lease) == true,
    "active output lease should release during lifecycle matrix cleanup"
)
assert(
    project_registry.prune(lease_project, "released output lease cleanup")
        == true,
    "released output lease should allow detached project pruning"
)

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
    project_store.all()[orphan_project.key] == orphan_project,
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
    project_store.all()[orphan_project.key] == nil,
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
rawset(compiler, "stop", function(state, callback)
    callback({
        code = 1,
        stale = false,
        stopped = false,
        error = "simulated stop failure",
    })
    return state.process
end)
local handled = lifecycle.stop_before_prune(
    stop_project,
    "stopping compiler in lifecycle failure test",
    "lifecycle failure test"
)

compiler.stop = original_compiler_stop

assert(handled, "lifecycle should handle active compiler cleanup")
assert(
    project_store.all()[stop_project.key] == stop_project,
    "failed compiler stop should retain project ownership"
)
assert(
    typst_test_compiler(stop_project).status == "stopping_failed",
    "failed compiler stop should mark stopping_failed"
)

typst_test_compiler(stop_project).process = nil
typst_test_compiler(stop_project).status = "idle"
project_registry.prune(stop_project, "test cleanup")

local mixed_project, mixed_bufnr =
    attach_project("preview-fails-compiler-stops")
mixed_project.bufs[mixed_bufnr] = nil
preview_service.set(mixed_project, {
    active = true,
    active_backend = "callback",
    status = "running",
})
typst_test_compiler(mixed_project).process = {
    is_closing = function()
        return false
    end,
}
typst_test_compiler(mixed_project).status = "watching"

local original_mixed_compiler_stop = compiler.stop
rawset(compiler, "stop", function(state, callback)
    typst_test_compiler(state).process = nil
    typst_test_compiler(state).watcher = nil
    typst_test_compiler(state).status = "idle"
    callback({
        code = 0,
        stale = false,
        stopped = true,
    })
    return nil
end)
local mixed_handled = lifecycle.stop_before_prune(
    mixed_project,
    "stopping compiler after preview failure in lifecycle matrix test",
    "preview failure with compiler success"
)

compiler.stop = original_mixed_compiler_stop

assert(mixed_handled, "mixed preview/compiler prune should be handled")
assert(
    project_store.all()[mixed_project.key] == mixed_project,
    "preview stop failure should retain project ownership"
)
assert(
    typst_test_preview(mixed_project).status == "stopping_failed",
    "preview stop failure should be recorded on preview state"
)
assert(
    typst_test_compiler(mixed_project).status == "idle",
    "successful compiler stop should not be overwritten by preview failure"
)

preview_service.set(mixed_project, {
    active = false,
    status = "idle",
    clear = {
        "active_backend",
        "last_result",
        "last_error",
        "stop_prune_reason",
    },
})
project_registry.prune(mixed_project, "test cleanup")

typst.reset({ force = true })
local prune_pending_stop_calls = 0
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("lifecycle-preview-prune-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            prune_pending_stop_calls = prune_pending_stop_calls + 1
            return pending_stop_handle()
        end,
    },
})
local preview_prune_project, preview_prune_bufnr =
    attach_project("preview-prune-pending")
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "pending prune preview should open"
)
preview_prune_project.bufs[preview_prune_bufnr] = nil

local preview_prune_handled = lifecycle.stop_before_prune(
    preview_prune_project,
    "stopping pending preview in lifecycle matrix test",
    "preview pending prune"
)

assert(preview_prune_handled, "pending preview prune should be handled")
assert(
    prune_pending_stop_calls == 1,
    "pending preview prune should request preview stop"
)
assert(
    typst_test_preview(preview_prune_project).active == true,
    "pending preview prune should keep active preview state"
)
assert(
    typst_test_preview(preview_prune_project).status == "stopping_failed",
    "pending preview prune should record unconfirmed stop status"
)
assert(
    typst_test_preview(preview_prune_project).stopping == true,
    "pending preview prune should record stopping=true"
)
assert(
    typst_test_preview(preview_prune_project).stop_prune_reason
        == "preview pending prune",
    "pending preview prune should record prune reason"
)
assert(
    project_store.all()[preview_prune_project.key] == preview_prune_project,
    "pending preview prune should retain project ownership"
)

typst.reset({ force = true })
local reset_pending_stop_calls = 0
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("lifecycle-preview-reset-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            reset_pending_stop_calls = reset_pending_stop_calls + 1
            return pending_stop_handle()
        end,
    },
})
local preview_reset_project = attach_project("preview-reset-pending")
assert(
    typst.viewer.preview({ mode = "document" }) == true,
    "pending reset preview should open"
)
local preview_reset_summary = typst.reset({ keep_telemetry = true })
assert(
    preview_reset_summary and preview_reset_summary.ok == false,
    "pending preview reset should report a retained resource"
)
assert(
    reset_pending_stop_calls == 1,
    "pending preview reset should request preview stop"
)
assert(
    typst_test_preview(preview_reset_project).active == true,
    "pending preview reset should keep active preview state"
)
assert(
    typst_test_preview(preview_reset_project).status == "stopping_failed",
    "pending preview reset should record unconfirmed stop status"
)
assert(
    typst_test_preview(preview_reset_project).stopping == true,
    "pending preview reset should record stopping=true"
)
assert(
    typst_test_preview(preview_reset_project).stop_prune_reason == "reset",
    "pending preview reset should record reset as stop reason"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("lifecycle-native-prune-output"),
    preview = {
        native = "browser",
    },
})
local native_prune_project, native_prune_bufnr =
    attach_project("preview-native-prune")
record_active_preview(native_prune_project, "native-browser")
native_prune_project.bufs[native_prune_bufnr] = nil

assert(
    lifecycle.stop_before_prune(
        native_prune_project,
        "stopping native preview in lifecycle matrix test",
        "native preview prune"
    ),
    "native preview prune should be handled"
)
assert(
    typst_test_preview(native_prune_project).active == false,
    "native preview prune should clear active preview state"
)
assert(
    project_store.all()[native_prune_project.key] == nil,
    "native preview prune should prune empty project"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("lifecycle-native-reset-output"),
    preview = {
        native = "browser",
    },
})
local native_reset_project = attach_project("preview-native-reset")
record_active_preview(native_reset_project, "native-browser")
local native_reset_summary = typst.reset({ keep_telemetry = true })
assert(
    native_reset_summary and native_reset_summary.ok == true,
    "native preview reset should stop cleanly"
)
assert(
    typst_test_preview(native_reset_project).active == false,
    "native preview reset should clear active preview state"
)

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
            stop_callback_registry_count = vim.tbl_count(project_store.all())
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
    vim.tbl_count(project_store.all()) == 0,
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
typst.project.set_main(exit_main)
local exit_snapshot = assert(typst.project.attach(0), "project should attach")
local exit_project = assert(project_store.get(exit_snapshot.key))

local cancel_opts = nil
---@type any
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
    not assert(project_services.operations(exit_project)).active_by_id[exit_record.id],
    "exit-cancelled operation should be removed from active records"
)

vim.cmd("qa!")
