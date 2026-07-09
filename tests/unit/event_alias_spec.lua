local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()

local api_contract = typst.contract()
assert(
    vim.tbl_contains(
        api_contract.event_payloads.TypstEventProjectAttach,
        "finalization_error"
    )
        and vim.tbl_contains(
            api_contract.event_payloads.TypstEventProjectAttach,
            "finalization_ok"
        ),
    "project attach contract should expose finalization result fields"
)
assert(
    api_contract.event_aliases.TypstBufferDetach
        and vim.tbl_contains(
            api_contract.event_aliases.TypstBufferDetach,
            "TypstEventBufferDetach"
        ),
    "event contract should expose buffer-detach alias"
)
assert(
    api_contract.event_aliases.TypstProjectPruned
        and vim.tbl_contains(
            api_contract.event_aliases.TypstProjectPruned,
            "TypstEventProjectPruned"
        ),
    "event contract should expose project-pruned event"
)
assert(
    vim.tbl_contains(api_contract.events, "TypstEventProjectDetach"),
    "deprecated project-detach TypstEvent alias should remain documented"
)
assert(
    vim.tbl_contains(api_contract.events, "TypstEventCompiling"),
    "deprecated compile progress TypstEvent alias should remain documented"
)
for _, event in ipairs(api_contract.compatibility_events or {}) do
    assert(
        api_contract.event_payloads[event],
        ("compatibility event should document payload fields: %s"):format(event)
    )
end
for event in pairs(api_contract.event_aliases or {}) do
    if not event:find("^TypstEvent") then
        assert(
            vim.tbl_contains(api_contract.compatibility_events, event),
            ("compatibility alias should be listed as compatibility event: %s"):format(
                event
            )
        )
    end
end

local seen = {}
local event_order = {}
local function record(pattern)
    vim.api.nvim_create_autocmd("User", {
        pattern = pattern,
        callback = function(args)
            seen[pattern] = seen[pattern] or {}
            seen[pattern][#seen[pattern] + 1] = args.data
            event_order[#event_order + 1] = {
                pattern = pattern,
                data = args.data,
            }
        end,
    })
end

local function assert_payload_documented(event, payload)
    local fields = api_contract.event_payloads[event] or {}
    for key in pairs(payload or {}) do
        assert(
            vim.tbl_contains(fields, key),
            ("%s payload field should be documented in contract: %s"):format(
                event,
                key
            )
        )
    end
end

for _, pattern in ipairs({
    "TypstEventInitPre",
    "TypstEventInitPost",
    "TypstEventConfigChanged",
    "TypstEventProjectAttach",
    "TypstEventBufferDetach",
    "TypstEventProjectPruned",
    "TypstEventCompileStarted",
    "TypstEventCompileSuccess",
    "TypstEventCompileFailed",
    "TypstEventCompileStopped",
    "TypstEventPreviewStarted",
    "TypstEventPreviewStopped",
    "TypstEventArtifactCreated",
    "TypstEventArtifactsCleaned",
    "TypstEventRenderCreated",
    "TypstEventTocCreated",
    "TypstEventTocActivated",
    "TypstEventQuit",
}) do
    record(pattern)
end
for _, pattern in ipairs(api_contract.compatibility_events or {}) do
    record(pattern)
end

local fail_next_compile = false

local provider = {
    name = "event-alias-provider",
    compile = function(project, callback)
        typst_test_compiler(project).last_command = {
            "event-alias-provider",
            "compile",
            project.main,
            typst_test_compiler(project).output,
        }
        typst_test_compiler(project).last_cwd = project.root
        callback({ code = fail_next_compile and 1 or 0, stale = false })
        fail_next_compile = false
        return nil
    end,
    start = function()
        return { kind = "watch", pending = true }
    end,
    stop = function(_, callback)
        if callback then
            callback({ code = 0, stale = false, stopped = true })
        end
        return nil
    end,
    status = function(project)
        return typst_test_compiler(project).status
    end,
    output = function(project)
        return typst_test_cache_path("event-alias-output/")
            .. vim.fn.fnamemodify(project.main, ":t:r")
            .. ".pdf"
    end,
}

local preview_opened = 0
local preview_stopped = 0

typst.setup({
    root = root,
    compile = {
        provider = provider,
    },
    preview = {
        open = function()
            preview_opened = preview_opened + 1
            return true
        end,
        stop = function()
            preview_stopped = preview_stopped + 1
            return true
        end,
    },
})
assert(
    seen.TypstEventInitPre and seen.TypstEventInitPre[1],
    "TypstEventInitPre should be emitted"
)
assert(
    seen.TypstEventInitPre[1].did_setup == false,
    "TypstEventInitPre should report pre-setup state"
)
assert_payload_documented("TypstEventInitPre", seen.TypstEventInitPre[1])
assert(
    seen.TypstEventInitPost and seen.TypstEventInitPost[1],
    "TypstEventInitPost should be emitted"
)
assert(
    seen.TypstEventInitPost[1].did_setup == true,
    "TypstEventInitPost should report post-setup state"
)

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local bufnr = vim.api.nvim_get_current_buf()
local project =
    assert(typst.project.attach(bufnr), "attach should return a project")

assert(
    seen.TypstEventProjectAttach and seen.TypstEventProjectAttach[1],
    "attach alias should be emitted"
)
assert(
    seen.TypstEventProjectAttach[1].key == project.key,
    "attach alias should include project key"
)
assert(
    seen.TypstEventProjectAttach[1].provider == "event-alias-provider",
    "attach alias should include provider"
)
assert(
    seen.TypstEventProjectAttach[1].finalization_ok == true,
    "successful attach events should expose finalization_ok"
)
assert_payload_documented(
    "TypstEventProjectAttach",
    seen.TypstEventProjectAttach[1]
)

local compile_done = false
local throwing_event_ran = false
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstCompileStarted",
    once = true,
    callback = function()
        throwing_event_ran = true
        error("forced user event failure")
    end,
})
typst.compiler.compile({ bufnr = bufnr }, function(result)
    compile_done = result.code == 0
end)
assert(compile_done, "compile callback should run")
assert(throwing_event_ran, "throwing user event should be exercised")
assert(
    seen.TypstEventCompileStarted and seen.TypstEventCompileStarted[1],
    "compile started alias should be emitted"
)
assert(
    seen.TypstEventCompiling and seen.TypstEventCompiling[1],
    "deprecated compile progress alias should be emitted"
)
assert_payload_documented("TypstEventCompiling", seen.TypstEventCompiling[1])
assert(
    seen.TypstEventCompileStarted[1].output:match(
        "event%-alias%-output/main%.pdf$"
    ),
    "compile started alias should include output"
)
assert(
    seen.TypstEventCompileSuccess and seen.TypstEventCompileSuccess[1],
    "compile success alias should be emitted"
)
assert(
    seen.TypstEventCompileSuccess[1].status == "success",
    "compile success alias should include final status"
)

fail_next_compile = true
typst.compiler.compile({ bufnr = bufnr })
assert(
    seen.TypstEventCompileFailed and seen.TypstEventCompileFailed[1],
    "compile failed alias should be emitted"
)
assert(
    seen.TypstEventCompileFailed[1].status == "error",
    "compile failed alias should include final status"
)

typst.compiler.watch({ bufnr = bufnr })
assert(
    seen.TypstEventCompileStarted[2],
    "watch should emit compile started alias"
)
typst.compiler.stop({ bufnr = bufnr })
assert(
    seen.TypstEventCompileStopped and seen.TypstEventCompileStopped[1],
    "stop alias should be emitted"
)
assert(
    seen.TypstEventCompileStopped[1].status == "idle",
    "stop alias should include idle status"
)

assert(
    typst.viewer.preview({ bufnr = bufnr, mode = "document" }) == true,
    "preview should open"
)
assert(preview_opened == 1, "preview open callback should run")
assert(
    seen.TypstEventPreviewStarted and seen.TypstEventPreviewStarted[1],
    "preview started alias should be emitted"
)
assert(
    seen.TypstEventPreviewStarted[1].preview_active == true,
    "preview started alias should report active state"
)

assert(
    typst.viewer.preview_stop({ bufnr = bufnr }) == true,
    "preview should stop"
)
assert(preview_stopped == 1, "preview stop callback should run")
assert(
    seen.TypstEventPreviewStopped and seen.TypstEventPreviewStopped[1],
    "preview stopped alias should be emitted"
)
assert(
    seen.TypstEventPreviewStopped[1].preview_active == false,
    "preview stopped alias should report inactive state"
)

local events = require("typst.core.events")
events.emit("TypstArtifactCreated", project, {
    id = "artifact-main-svg",
    path = typst_test_cache_path("event-alias-output/main.svg"),
    canonical_path = typst_test_cache_path("event-alias-output/main.svg"),
    format = "svg",
    profile = "default",
    command = { "typst", "compile", "main.typ", "main.svg" },
    status = "success",
    signature = {
        size = 123,
    },
    freshness = "fresh",
    reason = "created",
    producer = "test",
    preview_export = {
        target = "document",
    },
})
assert(
    seen.TypstEventArtifactCreated and seen.TypstEventArtifactCreated[1],
    "artifact created alias should be emitted"
)
assert(
    seen.TypstEventArtifactCreated[1].format == "svg",
    "artifact created alias should include artifact format"
)

events.emit("TypstArtifactsCleaned", project, {
    deleted = {
        typst_test_cache_path("event-alias-output/main.svg"),
    },
    failed = {},
    skipped = {},
    producer = "test",
})
assert(
    seen.TypstEventArtifactsCleaned and seen.TypstEventArtifactsCleaned[1],
    "artifacts cleaned alias should be emitted"
)
assert(
    #seen.TypstEventArtifactsCleaned[1].deleted == 1,
    "artifacts cleaned alias should include deleted paths"
)

events.emit("TypstRenderCreated", project, {
    path = typst_test_cache_path("event-alias-output/render.svg"),
    kind = "equation",
    source = typst_test_cache_path("event-alias-output/render.typ"),
    format = "svg",
    page = 1,
})
assert(
    seen.TypstEventRenderCreated and seen.TypstEventRenderCreated[1],
    "render created alias should be emitted"
)
assert(
    seen.TypstEventRenderCreated[1].kind == "equation",
    "render created alias should include render kind"
)

events.emit("TypstDiagnosticsPublished", project, {
    diagnostics_count = 2,
    diagnostic_buffers = 1,
    bufnr = bufnr,
})
assert(
    seen.TypstDiagnosticsPublished and seen.TypstDiagnosticsPublished[1],
    "diagnostics published compatibility event should be emitted"
)
assert(
    seen.TypstDiagnosticsPublished[1].diagnostics_count == 2,
    "diagnostics published compatibility event should include count"
)

events.emit("TypstDiagnosticsCleared", project, {
    diagnostics_count = 0,
    diagnostic_buffers = 0,
    bufnr = bufnr,
})
assert(
    seen.TypstDiagnosticsCleared and seen.TypstDiagnosticsCleared[1],
    "diagnostics cleared compatibility event should be emitted"
)

events.emit("TypstOutputCleaned", project, {
    output = typst_test_cache_path("event-alias-output/main.pdf"),
    output_deleted = true,
    temporary = {
        typst_test_cache_path("event-alias-output/main.aux"),
    },
    temporary_skipped = {},
    preview_artifacts = {},
    preview_artifacts_skipped = {},
    preview_artifacts_failed = {},
})
assert(
    seen.TypstOutputCleaned and seen.TypstOutputCleaned[1],
    "output cleaned compatibility event should be emitted"
)
assert(
    seen.TypstOutputCleaned[1].output_deleted == true,
    "output cleaned compatibility event should include output status"
)

events.emit("TypstViewOpened", project, {
    viewer_provider = "test-viewer",
    viewer_backend = "test-viewer-open",
    viewer_command = { "open", "main.pdf" },
    viewer_cwd = project.root,
})
assert(
    seen.TypstViewOpened and seen.TypstViewOpened[1],
    "view opened compatibility event should be emitted"
)
assert(
    seen.TypstViewOpened[1].viewer_provider == "test-viewer",
    "view opened compatibility event should include provider"
)

events.emit("TypstViewForwarded", project, {
    viewer_provider = "test-viewer",
    output = typst_test_cache_path("event-alias-output/main.pdf"),
    line = 3,
    column = 5,
    viewer_backend = "test-viewer-forward",
})
assert(
    seen.TypstViewForwarded and seen.TypstViewForwarded[1],
    "view forwarded compatibility event should be emitted"
)

events.emit("TypstViewInverse", project, {
    viewer_provider = "test-viewer",
    output = typst_test_cache_path("event-alias-output/main.pdf"),
    path = main,
    line = 4,
    column = 6,
    viewer_backend = "test-viewer-inverse",
})
assert(
    seen.TypstViewInverse and seen.TypstViewInverse[1],
    "view inverse compatibility event should be emitted"
)

events.emit("TypstPreviewForwarded", project, {
    backend = "test-preview",
    command = { "preview-forward" },
    output = typst_test_cache_path("event-alias-output/main.pdf"),
    line = 5,
    column = 7,
    source_sync = "forward",
})
assert(
    seen.TypstPreviewForwarded and seen.TypstPreviewForwarded[1],
    "preview forwarded compatibility event should be emitted"
)

events.emit("TypstPreviewInverse", project, {
    backend = "test-preview",
    path = main,
    output = typst_test_cache_path("event-alias-output/main.pdf"),
    line = 6,
    column = 8,
    source_sync = "inverse",
    page = 1,
    x = 12,
    y = 34,
})
assert(
    seen.TypstPreviewInverse and seen.TypstPreviewInverse[1],
    "preview inverse compatibility event should be emitted"
)

local created_before = #(seen.TypstEventTocCreated or {})
local activated_before = #(seen.TypstEventTocActivated or {})
local items = typst.navigation.toc({ bufnr = bufnr, open = false })
assert(type(items) == "table", "toc should return items")
assert(
    #seen.TypstEventTocCreated == created_before + 1,
    "toc created alias should be emitted"
)
assert(
    (seen.TypstEventTocActivated and #seen.TypstEventTocActivated or 0)
        == activated_before,
    "closed TOC should not activate"
)

items = typst.navigation.toc({ bufnr = bufnr })
assert(type(items) == "table", "opened toc should return items")
assert(
    #seen.TypstEventTocActivated == activated_before + 1,
    "opened TOC should emit activation alias"
)

vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })
assert(
    seen.TypstEventQuit and seen.TypstEventQuit[1],
    "quit alias should be emitted"
)
assert(
    seen.TypstEventQuit[1].projects >= 1,
    "quit alias should include project count"
)

typst.project.detach(bufnr)
assert(
    seen.TypstEventBufferDetach and seen.TypstEventBufferDetach[1],
    "buffer detach alias should be emitted"
)
assert(
    seen.TypstEventBufferDetach[1].event_kind == "buffer_detach",
    "buffer detach alias should identify buffer-detach semantics"
)
assert(
    seen.TypstEventBufferDetach[1].bufnr == bufnr,
    "buffer detach alias should include the detached buffer"
)
assert(
    seen.TypstEventBufferDetach[1].remaining_buffers == 0,
    "buffer detach alias should include remaining buffer count"
)
assert_payload_documented(
    "TypstEventBufferDetach",
    seen.TypstEventBufferDetach[1]
)
assert(
    seen.TypstEventProjectDetach and seen.TypstEventProjectDetach[1],
    "deprecated project-detach alias should be emitted"
)
assert(
    seen.TypstEventProjectDetach[1].event_kind == "buffer_detach",
    "deprecated project-detach alias should keep buffer-detach semantics"
)
assert_payload_documented(
    "TypstEventProjectDetach",
    seen.TypstEventProjectDetach[1]
)
assert(
    seen.TypstEventProjectPruned and seen.TypstEventProjectPruned[1],
    "project pruned event should be emitted when the project leaves the registry"
)
assert(
    seen.TypstEventProjectPruned[1].event_kind == "project_pruned",
    "project pruned event should identify project-pruned semantics"
)
assert(
    seen.TypstEventProjectPruned[1].remaining_buffers == 0,
    "project pruned event should report no remaining buffers"
)
assert_payload_documented(
    "TypstEventProjectPruned",
    seen.TypstEventProjectPruned[1]
)

local detach_index
local prune_index
for index, event in ipairs(event_order) do
    if
        event.data
        and event.data.key == project.key
        and event.pattern == "TypstEventBufferDetach"
    then
        detach_index = detach_index or index
    elseif
        event.data
        and event.data.key == project.key
        and event.pattern == "TypstEventProjectPruned"
    then
        prune_index = prune_index or index
    end
end
assert(
    detach_index and prune_index and detach_index < prune_index,
    "buffer detach event should be emitted before project pruned event"
)

local project_registry = require("typst.project")
local manual_prune_before = #(seen.TypstEventProjectPruned or {})
local manual_project = {
    key = "event-manual-prune",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    bufs = {},
    resolutions = {},
    services = require("typst.project.services").new_state(),
}
assert(
    project_registry.prune(manual_project, "manual prune test") == true,
    "manual project prune should report a pruned empty project"
)
project_registry.prune(manual_project, "manual prune duplicate")
project_registry.emit_pruned(manual_project, "manual prune duplicate")
assert(
    #(seen.TypstEventProjectPruned or {}) == manual_prune_before + 1,
    "manual project prune should emit TypstEventProjectPruned only once"
)

for pattern, payloads in pairs(seen) do
    for _, payload in ipairs(payloads) do
        assert_payload_documented(pattern, payload)
    end
end

local operations = require("typst.project.services.operations")
local project_services = require("typst.project.services")
local compiler_api = require("typst.compiler.api")

events._reset_for_tests()

local reentrant_project = {
    key = "event-reentrancy",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
    services = project_services.new_state(),
}

local original_compile = compiler_api.compile
local compile_calls = 0
local compile_callbacks = 0
local alias_saw_no_compile = false
local primary_saw_event = false
---@type any
local deferred_handle = nil

rawset(compiler_api, "compile", function(_, _, callback)
    compile_calls = compile_calls + 1
    callback({ code = 0, ok = true }, project)
    return { ok = true, code = 0 }
end)
local ok, err = xpcall(function()
    vim.api.nvim_create_autocmd("User", {
        pattern = "TypstProjectAttach",
        callback = function()
            primary_saw_event = events.in_user_event()
            deferred_handle = operations.compile(
                reentrant_project,
                {},
                function()
                    compile_callbacks = compile_callbacks + 1
                end
            )
            assert(
                deferred_handle and deferred_handle.deferred,
                "operation started from user event should be deferred"
            )
            assert(
                compile_calls == 0,
                "deferred operation should not run during primary event"
            )
        end,
    })
    vim.api.nvim_create_autocmd("User", {
        pattern = "TypstEventProjectAttach",
        callback = function()
            alias_saw_no_compile = compile_calls == 0
        end,
    })
    events.emit("TypstProjectAttach", reentrant_project)

    assert(primary_saw_event, "primary event should run inside event context")
    assert(
        alias_saw_no_compile,
        "queued state changes should wait for alias events to finish"
    )
    assert(
        compile_calls == 1,
        "deferred operation should run after event batch"
    )
    assert(
        compile_callbacks == 1,
        "deferred operation callback should run exactly once"
    )
    assert(
        deferred_handle.pending == false,
        "deferred proxy should settle after synchronous operation"
    )
end, debug.traceback)

compiler_api.compile = original_compile
events._reset_for_tests()

if not ok then
    error(err)
end

events._reset_for_tests()

local pending = require("typst.core.pending")
local pending_handle = nil
local pending_deferred_handle = nil
local pending_compile_calls = 0
local pending_compile_callbacks = 0

rawset(compiler_api, "compile", function(_, _, callback)
    pending_compile_calls = pending_compile_calls + 1
    pending_handle = pending.new({
        kind = "unit-deferred-compile",
        copy_result_fields = true,
    })
    pending_handle:on_finish(function(result)
        callback(result, reentrant_project)
    end)
    return pending_handle
end)

ok, err = xpcall(function()
    vim.api.nvim_create_autocmd("User", {
        pattern = "TypstUnitDeferredPending",
        once = true,
        callback = function()
            pending_deferred_handle = operations.compile(
                reentrant_project,
                {},
                function()
                    pending_compile_callbacks = pending_compile_callbacks + 1
                end
            )
            assert(
                pending_deferred_handle
                    and pending_deferred_handle.deferred
                    and pending_deferred_handle.pending,
                "pending operation started from user event should return a pending deferred proxy"
            )
            assert(
                pending_compile_calls == 0,
                "pending deferred operation should not run during the user event"
            )
        end,
    })

    events.emit("TypstUnitDeferredPending", reentrant_project)

    assert(
        pending_compile_calls == 1,
        "pending deferred operation should run after the event batch"
    )
    assert(
        pending_deferred_handle.pending == true,
        "deferred proxy should remain pending while the actual handle is pending"
    )
    assert(
        pending_handle and pending_handle.pending == true,
        "fake pending compiler handle should be active before finish"
    )

    pending_handle:finish({ ok = true, code = 0 })

    assert(
        vim.wait(1000, function()
            return pending_deferred_handle.pending == false
                and pending_deferred_handle.finished == true
        end, 10),
        "deferred proxy should settle after actual pending handle finishes"
    )
    assert(
        pending_deferred_handle.result
            and pending_deferred_handle.result.ok == true,
        "deferred proxy should retain the actual pending result"
    )
    assert(
        pending_compile_callbacks == 1,
        "pending deferred operation callback should run exactly once"
    )
end, debug.traceback)

compiler_api.compile = original_compile
events._reset_for_tests()

if not ok then
    error(err)
end

events._reset_for_tests()

local unobservable_deferred_handle = nil
local unobservable_compile_calls = 0

rawset(compiler_api, "compile", function()
    unobservable_compile_calls = unobservable_compile_calls + 1
    return {
        pending = true,
    }
end)

ok, err = xpcall(function()
    vim.api.nvim_create_autocmd("User", {
        pattern = "TypstUnitDeferredUnobservable",
        once = true,
        callback = function()
            unobservable_deferred_handle =
                operations.compile(reentrant_project, {})
            assert(
                unobservable_deferred_handle
                    and unobservable_deferred_handle.deferred,
                "unobservable deferred compile should return a deferred proxy"
            )
        end,
    })

    events.emit("TypstUnitDeferredUnobservable", reentrant_project)
    assert(
        unobservable_compile_calls == 1,
        "unobservable deferred compile should run after the event batch"
    )
    assert(
        unobservable_deferred_handle.pending == false
            and unobservable_deferred_handle.finished == true,
        "unobservable deferred proxy should settle immediately"
    )
    assert(
        unobservable_deferred_handle.reason == "pending_unobservable",
        "unobservable deferred proxy should expose a structured failure"
    )
end, debug.traceback)

compiler_api.compile = original_compile
events._reset_for_tests()

if not ok then
    error(err)
end

events._reset_for_tests()

local original_stop = compiler_api.stop
local cancel_compile_calls = 0
local cancel_callback_calls = 0
local cancel_deferred_handle = nil

rawset(compiler_api, "compile", function()
    cancel_compile_calls = cancel_compile_calls + 1
    return {
        pending = true,
        cancel_style = "dot",
        on_finish = function()
            return nil
        end,
        cancel = function(opts, callback)
            assert(
                type(opts) == "table" and opts.reason == "after-start",
                "deferred compile proxy should preserve dot-style cancel arguments"
            )
            local result = {
                ok = false,
                stopped = true,
                reason = opts.reason,
            }
            if type(callback) == "function" then
                callback(true, result)
            end
            return true, result
        end,
    }
end)

ok, err = xpcall(function()
    vim.api.nvim_create_autocmd("User", {
        pattern = "TypstUnitDeferredCancelCompile",
        once = true,
        callback = function()
            cancel_deferred_handle = operations.compile(reentrant_project, {})
        end,
    })

    events.emit("TypstUnitDeferredCancelCompile", reentrant_project)
    assert(cancel_compile_calls == 1, "deferred compile should have started")
    assert(
        cancel_deferred_handle and cancel_deferred_handle.pending == true,
        "deferred compile proxy should be pending before cancel"
    )
    local stopped, result = cancel_deferred_handle.cancel(
        { reason = "after-start" },
        function()
            cancel_callback_calls = cancel_callback_calls + 1
        end
    )
    assert(stopped == true, "deferred compile cancel should confirm stop")
    assert(
        result and result.reason == "after-start",
        "deferred compile cancel should return provider result"
    )
    assert(
        cancel_deferred_handle.pending == false
            and cancel_deferred_handle.finished == true,
        "deferred compile proxy should settle after cancel"
    )
    assert(
        cancel_callback_calls == 1,
        "deferred compile cancel should forward cancel callback"
    )
end, debug.traceback)

compiler_api.compile = original_compile
events._reset_for_tests()

if not ok then
    error(err)
end

local stop_calls = 0
local stop_cancel_callbacks = 0
local stop_deferred_handle = nil

rawset(compiler_api, "stop", function()
    stop_calls = stop_calls + 1
    return {
        pending = true,
        cancel_style = "dot",
        on_finish = function()
            return nil
        end,
        cancel = function(opts, callback)
            assert(
                type(opts) == "table" and opts.reason == "stop-after-start",
                "deferred stop proxy should preserve dot-style cancel arguments"
            )
            local result = {
                ok = false,
                stopped = true,
                reason = opts.reason,
            }
            if type(callback) == "function" then
                callback(true, result)
            end
            return true, result
        end,
    }
end)

ok, err = xpcall(function()
    vim.api.nvim_create_autocmd("User", {
        pattern = "TypstUnitDeferredCancelStop",
        once = true,
        callback = function()
            stop_deferred_handle = operations.stop(reentrant_project)
        end,
    })

    events.emit("TypstUnitDeferredCancelStop", reentrant_project)
    assert(stop_calls == 1, "deferred stop should have started")
    local stopped, result = stop_deferred_handle.cancel(
        { reason = "stop-after-start" },
        function()
            stop_cancel_callbacks = stop_cancel_callbacks + 1
        end
    )
    assert(stopped == true, "deferred stop cancel should confirm stop")
    assert(
        result and result.reason == "stop-after-start",
        "deferred stop cancel should return provider result"
    )
    assert(
        stop_deferred_handle.pending == false
            and stop_deferred_handle.finished == true,
        "deferred stop proxy should settle after cancel"
    )
    assert(
        stop_cancel_callbacks == 1,
        "deferred stop cancel should forward cancel callback"
    )
end, debug.traceback)

compiler_api.stop = original_stop
events._reset_for_tests()

if not ok then
    error(err)
end

vim.cmd("qa!")
