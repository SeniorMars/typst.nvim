local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry = require("typst.project")
local project_store = require("typst.project.store")
local root_discovery = require("typst.project.root")
local lifecycle = require("typst.project.lifecycle")
local operations = require("typst.project.services.operations")
local typst = require("typst")
local util = require("typst.core.util")

local function wait_for_suggestion(bufnr, expected_main)
    return vim.wait(1000, function()
        local state = registry.get(bufnr)
        local resolution = state
                and state.resolutions
                and state.resolutions[bufnr]
            or nil
        local suggestion = resolution and resolution.import_scan_suggestion
        return state ~= nil
            and state.resolution_pending == nil
            and suggestion ~= nil
            and util.same_path(suggestion.main, expected_main)
    end, 10)
end

local function assert_no_deferred_state(bufnr, message)
    local state = lifecycle._deferred_import_scan_state()
    assert(
        state.tokens[bufnr] == nil and state.handles[bufnr] == nil,
        message
    )
end

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()

local project_root = typst_test_cache_path("deferred-import-scan")
vim.fn.delete(project_root, "rf")
vim.fn.mkdir(project_root .. "/chapters", "p")
local main = util.normalize(project_root .. "/main.typ")
local leaf = util.normalize(project_root .. "/chapters/leaf.typ")
vim.fn.writefile({ "= Main", '#include "chapters/leaf.typ"' }, main)
vim.fn.writefile({ "= Leaf" }, leaf)

typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
vim.bo.filetype = "typst"
local bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()

local background_events = {}
local background_group = vim.api.nvim_create_augroup(
    "TypstDeferredImportScanBackgroundSpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = background_group,
    pattern = "TypstEventProjectAttach",
    callback = function(args)
        background_events[#background_events + 1] =
            vim.deepcopy(args.data or {})
    end,
})
local background_attached =
    assert(typst.project.attach(bufnr), "background fixture should attach")
assert(
    background_attached.resolution_pending == "import_scan",
    "background fixture should start with pending import scan"
)
assert(
    root_discovery._import_scan_stats().scans == 0,
    "background fixture should not scan imports inline"
)
assert(
    vim.wait(1000, function()
        local state = registry.get(bufnr)
        local resolution = state
                and state.resolutions
                and state.resolutions[bufnr]
            or nil
        local suggestion = resolution and resolution.import_scan_suggestion
        return state ~= nil
            and util.same_path(state.main, leaf)
            and state.resolution_pending == nil
            and suggestion
            and util.same_path(suggestion.main, main)
    end),
    "initial attach should schedule and settle deferred import-scan suggestion"
)
assert(
    background_events[1]
        and background_events[1].resolution_pending == "import_scan",
    "initial attach event should expose pending resolution"
)
local background_resolved = assert(typst.project.get(bufnr))
assert(
    util.same_path(background_resolved.main, main),
    "command-time lookup should accept the settled import-scan suggestion"
)
local background_transition =
    ((background_resolved.services or {}).lifecycle or {}).last_transition
assert(
    background_transition
        and background_transition.reason == "import scan suggestion accepted",
    "accepted suggestion should record lifecycle transition metadata"
)
assert(
    background_transition.previous_resolution
        and util.same_path(background_transition.previous_resolution.buffer, leaf)
        and background_transition.previous_resolution.import_scan_suggestion
        and util.same_path(
            background_transition.previous_resolution.import_scan_suggestion.main,
            main
        ),
    "accepted suggestion transition should preserve previous resolution metadata"
)
assert(
    background_events[#background_events]
        and background_events[#background_events].resolution_pending == nil
        and util.same_path(background_events[#background_events].main, main),
    "accepted suggestion should emit the resolved main"
)
vim.api.nvim_del_augroup_by_id(background_group)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()

typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
vim.bo.filetype = "typst"
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()

local attach_events = {}
local group =
    vim.api.nvim_create_augroup("TypstDeferredImportScanSpec", { clear = true })
vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "TypstEventProjectAttach",
    callback = function(args)
        attach_events[#attach_events + 1] = vim.deepcopy(args.data or {})
    end,
})
local attached = assert(typst.project.attach(bufnr), "buffer should attach")
local live_attached = assert(project_store.get(attached.key))
assert(
    util.same_path(attached.main, leaf),
    "attach should use the fast fallback before import scan"
)
assert(
    attached.resolution_pending == "import_scan",
    "attach should mark import scan as pending"
)
assert(
    attach_events[1] and attach_events[1].resolution_pending == "import_scan",
    "initial project attach event should expose pending import-scan state"
)
assert(
    root_discovery._import_scan_stats().scans == 0,
    "attach should not scan imports inline"
)
operations.begin(live_attached, "test-retained-operation")

local resolved = assert(
    typst.project.get(bufnr),
    "command-time project lookup should return a project"
)
assert(
    util.same_path(resolved.main, leaf),
    "lookup before scan completion should keep the fast fallback"
)
assert(
    wait_for_suggestion(bufnr, main),
    "deferred scan should settle a suggestion before command-time acceptance"
)
resolved = assert(typst.project.get(bufnr))
assert(
    util.same_path(resolved.main, main),
    "command-time project lookup should accept completed import-scan suggestion"
)
assert(
    resolved.resolution_pending == nil,
    "forced import scan should clear pending state"
)
assert(
    live_attached.resolution_pending == nil,
    "retained old fallback project should not keep stale pending state"
)
assert(
    project_store.all()[attached.key] == live_attached,
    "old fallback project should be retained by the active operation fixture"
)
assert(
    attach_events[#attach_events]
        and attach_events[#attach_events].resolution_pending == nil
        and util.same_path(attach_events[#attach_events].main, main),
    "final project attach event should expose the resolved main without pending state"
)
assert(
    root_discovery._import_scan_stats().scans == 1,
    "forced project lookup should run exactly one import scan"
)

vim.wait(100, function()
    return false
end)
assert(
    registry.get(bufnr).key == resolved.key,
    "stale scheduled deferred scan should not reassign after forced lookup"
)

typst.reset()

typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output-reset"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local reset_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before reset")
assert(
    reset_pending.resolution_pending == "import_scan",
    "reset fixture should start with a pending deferred scan"
)
typst.reset({ force = true })
vim.wait(80, function()
    return false
end)
assert(
    registry.get(bufnr) == nil,
    "reset should clear deferred import-scan tokens without reattaching stale buffers"
)
assert_no_deferred_state(bufnr, "reset should clear deferred scan local state")

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
local original_import_scan_main_async = root_discovery.import_scan_main_async
local fake_scan_called = false
local fake_scan_cancelled = false
local fake_scan_finish = nil
local fake_scan_handle = {
    pending = true,
    on_finish = function(self_or_callback, maybe_callback)
        fake_scan_finish = self_or_callback == fake_scan_handle
                and maybe_callback
            or self_or_callback
        return fake_scan_handle
    end,
    cancel = function(self)
        fake_scan_cancelled = true
        self.pending = false
        return true, { stopped = true, reason = "cancelled" }
    end,
}
root_discovery.import_scan_main_async = function()
    fake_scan_called = true
    return fake_scan_handle
end
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path(
        "deferred-import-scan-output-reset-handle"
    ),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local fake_handle_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before reset")
assert(
    fake_handle_pending.resolution_pending == "import_scan",
    "fake-handle fixture should start with pending import scan"
)
assert(
    vim.wait(1000, function()
        return fake_scan_called
    end, 10),
    "deferred import scan should create a pending handle before reset"
)
typst.reset({ force = true })
root_discovery.import_scan_main_async = original_import_scan_main_async
assert(
    fake_scan_cancelled,
    "lifecycle reset should cancel pending deferred import-scan handles"
)
assert_no_deferred_state(
    bufnr,
    "reset should clear pending deferred scan handle state"
)
if type(fake_scan_finish) == "function" then
    fake_scan_finish({
        ok = true,
        found = true,
        main = main,
        root = project_root,
        main_source = "import scan",
        root_source = "import scan root",
    })
end
vim.wait(80, function()
    return false
end)
assert(
    registry.get(bufnr) == nil,
    "late deferred import-scan callback after reset should not reattach"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
local throwing_import_scan_main_async = root_discovery.import_scan_main_async
local throwing_scan_called = false
root_discovery.import_scan_main_async = function()
    throwing_scan_called = true
    error("unit deferred import scan startup failure")
end
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path(
        "deferred-import-scan-output-startup-error"
    ),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local startup_error_pending = assert(
    typst.project.attach(bufnr),
    "buffer should attach before startup-error scan"
)
assert(
    startup_error_pending.resolution_pending == "import_scan",
    "startup-error fixture should start with pending import scan"
)
local startup_error_cleared = vim.wait(1000, function()
    local state = registry.get(bufnr)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
        or nil
    return throwing_scan_called
        and state ~= nil
        and state.resolution_pending == nil
        and resolution ~= nil
        and resolution.import_scan_status == "failed"
end, 10)
root_discovery.import_scan_main_async = throwing_import_scan_main_async
assert(
    startup_error_cleared,
    "deferred import scan startup errors should clear pending state"
)
assert_no_deferred_state(
    bufnr,
    "deferred import scan startup errors should clear local token state"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
local disabled_import_scan_main_async = root_discovery.import_scan_main_async
local disabled_scan_called = false
root_discovery.import_scan_main_async = function()
    disabled_scan_called = true
    return nil
end
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path(
        "deferred-import-scan-output-disabled"
    ),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local disabled_pending = assert(
    typst.project.attach(bufnr),
    "buffer should attach before disabled scan"
)
assert(
    disabled_pending.resolution_pending == "import_scan",
    "disabled fixture should start with pending import scan"
)
local disabled_cleared = vim.wait(1000, function()
    local state = registry.get(bufnr)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
        or nil
    return disabled_scan_called
        and state ~= nil
        and state.resolution_pending == nil
        and resolution ~= nil
        and resolution.import_scan_status == "disabled"
end, 10)
root_discovery.import_scan_main_async = disabled_import_scan_main_async
assert(
    disabled_cleared,
    "deferred import scan disabled result should clear pending state"
)
assert_no_deferred_state(
    bufnr,
    "deferred import scan disabled result should clear local token state"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
local reresolve_import_scan_main_async = root_discovery.import_scan_main_async
local reresolve_scan_called = false
local reresolve_scan_cancelled = false
local reresolve_scan_handle = {
    pending = true,
    on_finish = function()
        return reresolve_scan_handle
    end,
    cancel = function(self)
        reresolve_scan_cancelled = true
        self.pending = false
        return true, { stopped = true, reason = "buffer_reresolved" }
    end,
}
root_discovery.import_scan_main_async = function()
    reresolve_scan_called = true
    return reresolve_scan_handle
end
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path(
        "deferred-import-scan-output-reresolve-cancel"
    ),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local reresolve_pending = assert(
    typst.project.attach(bufnr),
    "buffer should attach before reresolve cancellation"
)
local reresolve_pending_live = assert(
    registry.get(bufnr),
    "reresolve fixture should expose live pending project state"
)
assert(
    reresolve_pending.resolution_pending == "import_scan",
    "reresolve fixture should start with pending import scan"
)
assert(
    vim.wait(1000, function()
        return reresolve_scan_called
    end, 10),
    "deferred import scan should create a pending handle before reresolve"
)
util.set_buf_var(bufnr, "typst_main", main)
local reresolved = assert(
    typst.project.get(bufnr),
    "command-time reresolve should return a project"
)
root_discovery.import_scan_main_async = reresolve_import_scan_main_async
assert(
    reresolve_scan_cancelled,
    "command-time reresolve should cancel the pending deferred scan"
)
assert(
    util.same_path(reresolved.main, main),
    "command-time reresolve should honor the explicit main"
)
local reresolve_resolution = reresolve_pending_live.resolutions
        and reresolve_pending_live.resolutions[bufnr]
    or nil
assert(
    reresolve_pending_live.resolution_pending == nil
        and (
            reresolve_resolution == nil
            or (
                reresolve_resolution.import_scan_pending ~= true
                and reresolve_resolution.resolution_pending == nil
                and reresolve_resolution.import_scan_request == nil
                and reresolve_resolution.import_scan_token == nil
            )
        ),
    "reresolve cancellation should clear stale pending import-scan metadata: "
        .. vim.inspect({
            project_pending = reresolve_pending_live.resolution_pending,
            resolution = reresolve_resolution,
        })
)
assert_no_deferred_state(
    bufnr,
    "reresolve cancellation should clear local token state"
)
util.del_buf_var(bufnr, "typst_main")
typst.reset({ force = true })
root_discovery._clear_import_scan_cache()

local failing_reresolve_import_scan_main_async =
    root_discovery.import_scan_main_async
local original_project_resolve = registry.resolve
local failing_reresolve_scan_called = false
local failing_reresolve_scan_cancelled = false
local failing_reresolve_handle = {
    pending = true,
    on_finish = function()
        return failing_reresolve_handle
    end,
    cancel = function(self)
        failing_reresolve_scan_cancelled = true
        self.pending = false
        return true, { stopped = true, reason = "buffer_reresolved" }
    end,
}
root_discovery.import_scan_main_async = function()
    failing_reresolve_scan_called = true
    return failing_reresolve_handle
end
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path(
        "deferred-import-scan-output-reresolve-failure"
    ),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local failing_reresolve_pending = assert(
    typst.project.attach(bufnr),
    "buffer should attach before failing reresolve cancellation"
)
local failing_reresolve_live = assert(
    registry.get(bufnr),
    "failing reresolve fixture should expose live pending project state"
)
assert(
    failing_reresolve_pending.resolution_pending == "import_scan",
    "failing reresolve fixture should start with pending import scan"
)
assert(
    vim.wait(1000, function()
        return failing_reresolve_scan_called
    end, 10),
    "deferred import scan should create a pending handle before failing reresolve"
)
util.set_buf_var(bufnr, "typst_main", main)
registry.resolve = function()
    error("synthetic reresolve failure")
end
local failed_ok = pcall(typst.project.get, bufnr)
registry.resolve = original_project_resolve
root_discovery.import_scan_main_async = failing_reresolve_import_scan_main_async
assert(
    failed_ok == false,
    "failing reresolve fixture should exercise the reresolve error path"
)
assert(
    failing_reresolve_scan_cancelled,
    "failing command-time reresolve should cancel pending deferred scan"
)
local failing_reresolve_resolution = failing_reresolve_live.resolutions
        and failing_reresolve_live.resolutions[bufnr]
    or nil
assert(
    failing_reresolve_live.resolution_pending == nil
        and failing_reresolve_resolution
        and failing_reresolve_resolution.import_scan_pending ~= true
        and failing_reresolve_resolution.resolution_pending == nil
        and failing_reresolve_resolution.import_scan_request == nil
        and failing_reresolve_resolution.import_scan_token == nil,
    "failing reresolve should clear stale pending import-scan metadata: "
        .. vim.inspect({
            project_pending = failing_reresolve_live.resolution_pending,
            resolution = failing_reresolve_resolution,
        })
)
assert_no_deferred_state(
    bufnr,
    "failing reresolve cancellation should clear local token state"
)
util.del_buf_var(bufnr, "typst_main")
typst.reset({ force = true })
root_discovery._clear_import_scan_cache()

typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output-detach"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local detach_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before detach")
assert(
    detach_pending.resolution_pending == "import_scan",
    "detach fixture should start with pending import scan"
)
typst.project.detach(bufnr)
vim.wait(80, function()
    return false
end)
assert(
    registry.get(bufnr) == nil,
    "detaching a pending buffer should clear its registry association"
)
assert(
    project_store.get(detach_pending.key) == nil
        or project_store.get(detach_pending.key).resolution_pending == nil,
    "detaching before the timer fires should clear pending project state"
)

typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output-rename"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local path_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before rename")
assert(
    path_pending.resolution_pending == "import_scan",
    "rename fixture should start with pending import scan"
)
require("typst.core.lifecycle").clear_buffer(bufnr)
vim.api.nvim_buf_set_name(
    bufnr,
    util.normalize(project_root .. "/chapters/renamed.typ")
)
local path_changed_cleared = vim.wait(1000, function()
    local state = registry.get(bufnr)
    local resolution = state and state.resolutions and state.resolutions[bufnr]
        or nil
    return state ~= nil
        and state.resolution_pending == nil
        and resolution ~= nil
        and resolution.import_scan_status == "path_changed"
end)
assert(
    path_changed_cleared,
    "deferred scan should clear pending state when buffer path changes"
)
assert_no_deferred_state(
    bufnr,
    "deferred scan path change should clear local token state"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
local command_calls = {}
local command_provider = {
    name = "deferred-import-command-provider",
    compile = function(state, callback)
        command_calls[#command_calls + 1] = {
            method = "compile",
            main = state.main,
        }
        callback({ code = 0, stale = false })
        return { provider = "deferred-import-command" }
    end,
    start = function(state, callback)
        command_calls[#command_calls + 1] = {
            method = "start",
            main = state.main,
        }
        if callback then
            callback({ code = 0, stale = false })
        end
        return { provider = "deferred-import-command" }
    end,
    stop = function(_, callback)
        if callback then
            callback({ code = 0, stale = false, stopped = true })
        end
    end,
    status = function()
        return "idle"
    end,
    output = function()
        return typst_test_cache_path("deferred-import-command/output.pdf")
    end,
}
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output-command"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
    compile = {
        provider = command_provider,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local command_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before command")
assert(
    command_pending.resolution_pending == "import_scan",
    "command fixture should start with pending import scan"
)
assert(
    wait_for_suggestion(bufnr, main),
    "command fixture should record a suggestion before compile"
)
local original_notify = vim.notify
rawset(vim, "notify", function() end)
local command_ok, command_err = pcall(function()
    vim.cmd("TypstCompile")
end)
rawset(vim, "notify", original_notify)
assert(command_ok, tostring(command_err))
assert(
    command_calls[1] and util.same_path(command_calls[1].main, main),
    ":TypstCompile should accept completed import-scan suggestion before provider call"
)
assert(
    command_calls[1].method == "compile",
    ":TypstCompile should invoke the compile provider"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
command_calls = {}
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output-watch"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
    compile = {
        provider = command_provider,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local watch_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before watch")
assert(
    watch_pending.resolution_pending == "import_scan",
    "watch fixture should start with pending import scan"
)
assert(
    wait_for_suggestion(bufnr, main),
    "watch fixture should record a suggestion before watch"
)
original_notify = vim.notify
rawset(vim, "notify", function() end)
local watch_ok, watch_err = pcall(function()
    vim.cmd("TypstWatch")
end)
rawset(vim, "notify", original_notify)
assert(watch_ok, tostring(watch_err))
assert(
    command_calls[1]
        and command_calls[1].method == "start"
        and util.same_path(command_calls[1].main, main),
    ":TypstWatch should accept completed import-scan suggestion before provider start"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
local preview_calls = {}
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output-preview"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
    preview = {
        open = function(state, opts)
            preview_calls[#preview_calls + 1] = {
                main = state.main,
                mode = opts.mode,
            }
            return true
        end,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local preview_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before preview")
assert(
    preview_pending.resolution_pending == "import_scan",
    "preview fixture should start with pending import scan"
)
assert(
    wait_for_suggestion(bufnr, main),
    "preview fixture should record a suggestion before preview"
)
original_notify = vim.notify
rawset(vim, "notify", function() end)
local preview_ok, preview_err = pcall(function()
    vim.cmd("TypstPreview document")
end)
rawset(vim, "notify", original_notify)
assert(preview_ok, tostring(preview_err))
assert(
    preview_calls[1]
        and preview_calls[1].mode == "document"
        and util.same_path(preview_calls[1].main, main),
    ":TypstPreview should accept completed import-scan suggestion before opening preview"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output-toc"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
    toc = {
        mode = "quickfix",
        mappings = {
            enabled = false,
        },
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local toc_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before TOC")
assert(
    toc_pending.resolution_pending == "import_scan",
    "TOC fixture should start with pending import scan"
)
assert(
    wait_for_suggestion(bufnr, main),
    "TOC fixture should record a suggestion before navigation"
)
original_notify = vim.notify
rawset(vim, "notify", function() end)
local toc_ok, toc_err = pcall(function()
    vim.cmd("TypstToc")
end)
rawset(vim, "notify", original_notify)
assert(toc_ok, tostring(toc_err))
local toc_state = registry.get(bufnr)
assert(
    toc_state
        and toc_state.resolution_pending == nil
        and util.same_path(toc_state.main, main),
    ":TypstToc should accept completed import-scan suggestion before collecting navigation"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
local pick_calls = {}
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("deferred-import-scan-output-pick"),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
    picker = {
        provider = "custom",
        custom = function(items, opts)
            pick_calls[#pick_calls + 1] = {
                items = items,
                kind = opts.kind,
                main = (registry.get(bufnr) or {}).main,
            }
            return { ok = true, backend = "deferred-import-pick" }
        end,
    },
})
vim.cmd.edit(vim.fn.fnameescape(leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local pick_pending =
    assert(typst.project.attach(bufnr), "buffer should attach before picker")
assert(
    pick_pending.resolution_pending == "import_scan",
    "picker fixture should start with pending import scan"
)
assert(
    wait_for_suggestion(bufnr, main),
    "picker fixture should record a suggestion before picker collection"
)
original_notify = vim.notify
rawset(vim, "notify", function() end)
local pick_ok, pick_err = pcall(function()
    vim.cmd("TypstPick")
end)
rawset(vim, "notify", original_notify)
assert(pick_ok, tostring(pick_err))
local pick_state = registry.get(bufnr)
assert(
    pick_calls[1]
        and pick_state
        and pick_state.resolution_pending == nil
        and util.same_path(pick_state.main, main)
        and util.same_path(pick_calls[1].main, main),
    ":TypstPick should accept completed import-scan suggestion before collecting picker items"
)

typst.reset({ force = true })
root_discovery._clear_import_scan_cache()
local event_root = typst_test_cache_path("deferred-import-scan-event-watch")
vim.fn.delete(event_root, "rf")
vim.fn.mkdir(event_root .. "/chapters", "p")
local event_main = util.normalize(event_root .. "/main.typ")
local event_leaf = util.normalize(event_root .. "/chapters/leaf.typ")
vim.fn.writefile({ "= Main", '#include "chapters/leaf.typ"' }, event_main)
vim.fn.writefile({ "= Leaf" }, event_leaf)
local watch_calls = {}
local event_watch_provider = {
    name = "deferred-import-event-watch-provider",
    compile = function(state, callback)
        if callback then
            callback({ code = 0, stale = false })
        end
        return { provider = "deferred-import-event-watch" }
    end,
    start = function(state)
        watch_calls[#watch_calls + 1] = {
            method = "start",
            main = state.main,
        }
        return { provider = "deferred-import-event-watch" }
    end,
    stop = function(_, callback)
        if callback then
            callback({ code = 0, stale = false, stopped = true })
        end
    end,
    status = function()
        return "idle"
    end,
    output = function()
        return typst_test_cache_path("deferred-import-event-watch/output.pdf")
    end,
}
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path(
        "deferred-import-scan-output-event-watch"
    ),
    project = {
        import_scan = true,
        import_scan_max_depth = 1,
        import_scan_max_files = 20,
    },
    compile = {
        provider = event_watch_provider,
    },
})
vim.cmd.edit(vim.fn.fnameescape(event_leaf))
bufnr = vim.api.nvim_get_current_buf()
typst.project.detach(bufnr)
root_discovery._clear_import_scan_cache()
local event_watch_group = vim.api.nvim_create_augroup(
    "TypstDeferredImportScanEventWatchSpec",
    { clear = true }
)
local pending_attach_seen = false
local settled_attach_seen = false
local watch_errors = {}
vim.api.nvim_create_autocmd("User", {
    group = event_watch_group,
    pattern = "TypstEventProjectAttach",
    callback = function(args)
        local data = args.data or {}
        if data.resolution_pending then
            pending_attach_seen = true
            return
        end
        settled_attach_seen = true
    end,
})
original_notify = vim.notify
rawset(vim, "notify", function() end)
local event_pending = assert(
    typst.project.attach(bufnr),
    "buffer should attach before event watch"
)
assert(
    event_pending.resolution_pending == "import_scan",
    "event-watch fixture should start with pending import scan"
)
assert(
    wait_for_suggestion(bufnr, event_main),
    "event-watch fixture should record a suggestion"
)
assert(
    settled_attach_seen == false,
    "deferred import scan should not emit a background settled attach event"
)
if vim.api.nvim_buf_is_valid(bufnr) then
    local ok, err = pcall(typst.compiler.watch, { bufnr = bufnr })
    if not ok then
        watch_errors[#watch_errors + 1] = tostring(err)
    end
end
local event_watch_ok = vim.wait(1000, function()
    return watch_calls[1] and util.same_path(watch_calls[1].main, event_main)
end)
rawset(vim, "notify", original_notify)
vim.api.nvim_del_augroup_by_id(event_watch_group)
assert(
    pending_attach_seen,
    "attach-event handlers should be able to observe pending import scan"
)
assert(
    settled_attach_seen == true,
    "accepting a suggestion should emit the resolved attach event"
)
assert(
    event_watch_ok,
    "command-time watch should accept the suggested main: "
        .. table.concat(watch_errors, "; ")
)

vim.cmd("qa!")
