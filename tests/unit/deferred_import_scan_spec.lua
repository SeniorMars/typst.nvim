local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry = require("typst.project")
local project_store = require("typst.project.store")
local root_discovery = require("typst.project.root")
local operations = require("typst.project.services.operations")
local typst = require("typst")
local util = require("typst.core.util")

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
        return state ~= nil
            and util.same_path(state.main, main)
            and state.resolution_pending == nil
    end),
    "initial attach should schedule and settle deferred import scan"
)
assert(
    background_events[1]
        and background_events[1].resolution_pending == "import_scan",
    "initial attach event should expose pending resolution"
)
assert(
    background_events[#background_events]
        and background_events[#background_events].resolution_pending == nil
        and util.same_path(background_events[#background_events].main, main),
    "settled attach event should expose the resolved main"
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
    util.same_path(resolved.main, main),
    "command-time project lookup should force pending import scan"
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
local original_notify = vim.notify
rawset(vim, "notify", function() end)
local command_ok, command_err = pcall(function()
    vim.cmd("TypstCompile")
end)
rawset(vim, "notify", original_notify)
assert(command_ok, tostring(command_err))
assert(
    command_calls[1] and util.same_path(command_calls[1].main, main),
    ":TypstCompile should resolve pending import scan before provider call"
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
    ":TypstWatch should resolve pending import scan before provider start"
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
    ":TypstPreview should resolve pending import scan before opening preview"
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
    ":TypstToc should resolve pending import scan before collecting navigation"
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
    ":TypstPick should resolve pending import scan before collecting picker items"
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
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                local ok, err = pcall(typst.compiler.watch, { bufnr = bufnr })
                if not ok then
                    watch_errors[#watch_errors + 1] = tostring(err)
                end
            end
        end)
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
    settled_attach_seen,
    "deferred import scan should emit a settled attach event"
)
assert(
    event_watch_ok,
    "settled attach event should let handlers start watch on the resolved main: "
        .. table.concat(watch_errors, "; ")
)

vim.cmd("qa!")
