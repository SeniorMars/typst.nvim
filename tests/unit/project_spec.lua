local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry = require("typst.project")
local config = require("typst.config")
local project_store = require("typst.project.store")
local util = require("typst.core.util")
local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("test-output"),
    project = {
        import_scan = false,
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
local chapter = root .. "/tests/fixtures/basic/chapter.typ"
local state_store = require("typst.core.state")
state_store.clear_explicit_main(chapter)

vim.cmd.edit(chapter)
local bufnr = vim.api.nvim_get_current_buf()
local standalone_snapshot = typst.project.get(bufnr)
local standalone = assert(project_store.get(standalone_snapshot.key))
assert(
    standalone.main == chapter,
    "chapter should start as a standalone project"
)
assert(
    standalone.bufs[bufnr],
    "standalone project should own the current buffer"
)

local missing_main = root .. "/tests/fixtures/basic/missing-main.typ"
local missing_ok, missing_err = pcall(function()
    typst.project.set_main(missing_main, nil, { persist = true })
end)
assert(not missing_ok, "set_main should reject unreadable main paths")
assert(
    tostring(missing_err):find("Typst main file is not readable", 1, true),
    "set_main should report unreadable main paths clearly"
)
assert(
    vim.b.typst_main == nil,
    "set_main should not write buffer state for unreadable main paths"
)
assert(
    state_store.explicit_main(chapter) == nil,
    "set_main should not persist unreadable main paths"
)

local project = typst.project.set_main(main)
local live_project = assert(project_store.get(project.key))

assert(
    project.root == root,
    ("expected root %s, got %s"):format(root, project.root)
)
assert(
    project.main == main,
    ("expected main %s, got %s"):format(main, project.main)
)
assert(
    typst_test_compiler(project).output
        == typst_test_cache_path("test-output/main.pdf"),
    typst_test_compiler(project).output
)
assert(
    not standalone.bufs[bufnr],
    "old project should release buffer after TypstSetMain"
)
assert(
    not standalone.resolutions[bufnr],
    "old project should release buffer resolution after TypstSetMain"
)
assert(
    project_store.all()[standalone.key] == nil,
    "empty old project should be removed after TypstSetMain"
)

local same = typst.project.get(0)
assert(same.key == project.key, "buffer should keep the same project key")

local nil_opts_ok, nil_opts_project = pcall(function()
    return registry.resolve(bufnr)
end)
assert(
    nil_opts_ok and nil_opts_project and nil_opts_project.key == project.key,
    "project.resolve should accept nil resolution options"
)

local raw_registry = require("typst.project.registry")
local registry_copy = raw_registry.all()
registry_copy[project.key] = nil
assert(
    raw_registry.get(project.key) == live_project,
    "project registry all() should not expose the mutable project map"
)
local buffer_registry_copy = raw_registry.buffers()
buffer_registry_copy[bufnr] = nil
assert(
    raw_registry.key_for_buffer(bufnr) == project.key,
    "project registry buffers() should not expose the mutable buffer map"
)

local bogus_bufnr = bufnr + 10000
raw_registry.set_buffer(bogus_bufnr, "missing-project-key")
local invariant_result = require("typst.internal.debug").check_invariants()
raw_registry.clear_buffer(bogus_bufnr)
local reported_missing_mapping = false
for _, finding in ipairs(invariant_result.findings or {}) do
    if finding.code == "buffer_mapping_missing_project" then
        reported_missing_mapping = true
        break
    end
end
assert(
    reported_missing_mapping,
    "TypstDoctor invariant check should report stale buffer project mappings"
)

project = typst.project.set_main(main, nil, { persist = true })
local failed_ok = pcall(function()
    typst.project.set_main(missing_main, nil, { persist = true })
end)
assert(
    not failed_ok,
    "failed set_main should reject unreadable paths after a valid main"
)
assert(
    vim.b.typst_main == main,
    "failed set_main should preserve previous buffer-local main"
)
assert(
    state_store.explicit_main(chapter) == main,
    "failed set_main should preserve previous persisted main"
)
assert(
    typst.project.get(bufnr).key == project.key,
    "failed set_main should keep the existing project attached"
)

local project_module = require("typst.project")
local original_commit_attach = project_module.commit_attach
local rollback_ok, rollback_err = xpcall(function()
    rawset(project_module, "commit_attach", function()
        error("forced commit failure")
    end)
    local ok = pcall(function()
        typst.project.set_main(chapter, nil, { persist = true })
    end)
    assert(not ok, "set_main should surface commit failures")
    assert(
        vim.b.typst_main == main,
        "set_main should roll back buffer-local main after commit failure"
    )
    assert(
        state_store.explicit_main(chapter) == main,
        "set_main should roll back persisted main after commit failure"
    )
end, debug.traceback)
project_module.commit_attach = original_commit_attach
if not rollback_ok then
    error(rollback_err)
end

local output_cfg = config.unsafe_get()
local original_output_dir = output_cfg.output_dir
local original_allow_external_output = output_cfg.allow_external_output
local outside_output_dir = vim.fn.tempname() .. "-typst-nvim-output"
vim.fn.mkdir(outside_output_dir, "p")
output_cfg.output_dir = outside_output_dir
output_cfg.allow_external_output = false
local previous_project_key = project_store.key_for_buffer(bufnr)
local output_reloaded = typst.project.set_main(chapter, nil, { persist = true })
local output_reloaded_live =
    assert(project_store.get(output_reloaded.key), "output fixture project")
local output_compile_result = typst.compiler.compile({ notify = false })
output_cfg.output_dir = original_output_dir
output_cfg.allow_external_output = original_allow_external_output
assert(
    output_reloaded and output_reloaded.main == chapter,
    "set_main should tolerate invalid planned output config"
)
assert(
    typst_test_compiler(output_reloaded_live).output == nil,
    "invalid planned output should not be stored during set_main"
)
assert(
    type(output_compile_result) == "table"
        and output_compile_result.reason == "output_path_invalid",
    "compile should surface output path validation failures"
)
assert(
    vim.b.typst_main == chapter,
    "set_main should keep the requested buffer-local main"
)
assert(
    state_store.explicit_main(chapter) == chapter,
    "set_main should persist the requested main"
)

project = typst.project.set_main(main, nil, { persist = true })
assert(
    project_store.key_for_buffer(bufnr) == previous_project_key,
    "test fixture should be restored to the previous project"
)

local graph_sources = require("typst.project.graph.sources")
local attachment_index = require("typst.project.attachments.index")
local transaction_diagnostics = require("typst.diagnostics")
local compiler_service = require("typst.project.services.compiler")
local original_graph_add = graph_sources.add
local transaction_failure_ok, transaction_failure_err = xpcall(function()
    local previous_key = project_store.key_for_buffer(bufnr)
    local previous_live = assert(project_store.get(previous_key))
    compiler_service.set(previous_live, {
        outputless = true,
    })
    local namespace = transaction_diagnostics.namespace_for(previous_live)
    vim.diagnostic.set(namespace, bufnr, {
        {
            lnum = 0,
            col = 0,
            message = "rollback diagnostic",
            severity = vim.diagnostic.severity.ERROR,
        },
    }, {})
    assert(
        attachment_index.should_mark_dirty(previous_live, {
            event = "TextChanged",
            buf = bufnr,
        }),
        "dirty tick fixture should create a debounce entry"
    )

    rawset(graph_sources, "add", function(target_project, added_path, source)
        if target_project.key == project_store.project_key(root, chapter) then
            error("forced graph add failure")
        end
        return original_graph_add(target_project, added_path, source)
    end)

    local ok = pcall(function()
        typst.project.set_main(chapter, nil, { persist = true })
    end)
    assert(not ok, "set_main should surface post-transfer commit failures")
    assert(
        vim.b.typst_main == main,
        "post-transfer failure should roll back buffer-local main"
    )
    assert(
        state_store.explicit_main(chapter) == main,
        "post-transfer failure should roll back persisted main"
    )
    assert(
        project_store.key_for_buffer(bufnr) == previous_key,
        "post-transfer failure should restore previous buffer ownership"
    )
    assert(
        project_store.get(previous_key) == previous_live,
        "post-transfer failure should restore the previous project object"
    )
    assert(
        project_store.get(project_store.project_key(root, chapter)) == nil,
        "post-transfer failure should remove the failed candidate project"
    )
    assert(
        previous_live.bufs[bufnr] == true,
        "post-transfer failure should restore project buffer membership"
    )
    assert(
        previous_live.resolutions[bufnr] ~= nil,
        "post-transfer failure should restore buffer resolution metadata"
    )
    assert(
        graph_sources.get(previous_live)[main] == true
            and graph_sources.get(previous_live)[chapter] == true,
        "post-transfer failure should restore graph source membership"
    )
    assert(
        (compiler_service.get(previous_live) or {}).outputless == true,
        "post-transfer failure should restore compiler outputless state"
    )
    assert(
        #vim.diagnostic.get(bufnr, { namespace = namespace }) == 1,
        "post-transfer failure should restore previous diagnostics"
    )
    assert(not attachment_index.should_mark_dirty(previous_live, {
        event = "TextChanged",
        buf = bufnr,
    }), "post-transfer failure should restore dirty tick debounce state")
end, debug.traceback)
graph_sources.add = original_graph_add
if not transaction_failure_ok then
    error(transaction_failure_err)
end

local original_resolve_candidate = project_module.resolve_candidate
local clear_failed_ok, clear_failed_err = xpcall(function()
    rawset(project_module, "resolve_candidate", function()
        error("forced clear-main resolution failure")
    end)
    local ok = pcall(function()
        typst.project.clear_main(bufnr, { clear_persisted = true })
    end)
    assert(not ok, "clear_main should surface resolution failures")
    assert(
        vim.b.typst_main == main,
        "clear_main failure should roll back buffer-local main"
    )
    assert(
        state_store.explicit_main(chapter) == main,
        "clear_main failure should roll back persisted main"
    )
    assert(
        project_store.key_for_buffer(bufnr) == previous_project_key,
        "clear_main failure should keep previous buffer ownership"
    )
end, debug.traceback)
project_module.resolve_candidate = original_resolve_candidate
if not clear_failed_ok then
    error(clear_failed_err)
end

local forced_missing = root .. "/tests/fixtures/basic/generated-later.typ"
vim.fn.delete(forced_missing)
local forced_project =
    typst.project.set_main(forced_missing, nil, { force = true })
assert(
    forced_project.main == forced_missing,
    "force=true should allow an unreadable explicit main for this resolution"
)
assert(
    vim.b.typst_main == forced_missing,
    "force=true should keep the unreadable explicit main in buffer state"
)
assert(
    forced_project.resolutions[bufnr]
        and forced_project.resolutions[bufnr].allow_unreadable_explicit_main
            == true,
    "forced unreadable main should be recorded in resolution metadata"
)
assert(
    not registry.main_stale(forced_project, bufnr),
    "forced unreadable main should not be immediately considered stale"
)
local persisted_dir = vim.fn.tempname()
vim.fn.mkdir(persisted_dir, "p")
local persisted_chapter = persisted_dir .. "/chapter.typ"
local persisted_forced_missing = persisted_dir .. "/generated-later.typ"
vim.fn.writefile({ "= Chapter" }, persisted_chapter)
state_store.set_explicit_main(persisted_chapter, persisted_forced_missing)
vim.cmd.edit(vim.fn.fnameescape(persisted_chapter))
vim.b.typst_main = nil
local persisted_missing = registry.resolve(0)
assert(
    persisted_missing.main ~= persisted_forced_missing,
    "unreadable persisted explicit mains should not reuse force semantics"
)
assert(
    state_store.explicit_main(persisted_chapter) == nil,
    "unreadable persisted explicit mains should be ignored until readable"
)
vim.fn.writefile({ "= Generated" }, persisted_forced_missing)
assert(
    util.same_path(
        state_store.explicit_main(persisted_chapter),
        persisted_forced_missing
    ),
    "unreadable persisted explicit mains should be retained for later recovery"
)
vim.cmd.edit(chapter)
bufnr = vim.api.nvim_get_current_buf()
project = typst.project.set_main(main, nil, { persist = true })
vim.cmd.edit(chapter)
vim.b.typst_main = main
local resolved = typst.project.get(0)
assert(
    resolved.main == main,
    "chapter should resolve to the configured main file"
)
assert(
    vim.api.nvim_buf_get_name(0) == chapter,
    "edit_main test should start in the included chapter buffer"
)

local opened = typst.project.edit_main()
assert(opened == main, "edit_main should return the resolved main path")
assert(
    vim.api.nvim_buf_get_name(0) == main,
    "edit_main should open the resolved main file"
)

vim.cmd.edit(chapter)
vim.b.typst_main = main
vim.cmd.TypstEditMain()
assert(
    vim.api.nvim_buf_get_name(0) == main,
    ":TypstEditMain should open the resolved main file"
)

local tests_dir = root .. "/tests"
vim.cmd.edit(main)
typst.project.set_main(main)

vim.cmd.lcd(vim.fn.fnameescape(tests_dir))
assert(
    vim.fn.getcwd(0) == tests_dir,
    "project cd test should start with a window-local cwd away from project root"
)

local local_root = typst.project.cd()
assert(local_root == root, "cd() should return the resolved project root")
assert(
    vim.fn.getcwd(0) == root,
    "cd() should change the current window cwd to the project root"
)

vim.cmd.lcd(vim.fn.fnameescape(tests_dir))
vim.cmd.TypstCd()
assert(
    vim.fn.getcwd(0) == root,
    ":TypstCd should change the current window cwd to the project root"
)

vim.cmd.cd(vim.fn.fnameescape(tests_dir))
typst.project.cd({ global = true })
assert(
    vim.fn.getcwd(-1, -1) == root,
    "cd({ global = true }) should change the global cwd"
)

vim.cmd.cd(vim.fn.fnameescape(tests_dir))
vim.cmd("TypstCd!")
assert(vim.fn.getcwd(-1, -1) == root, ":TypstCd! should change the global cwd")

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-attach-transaction-output"),
    project = {
        import_scan = false,
    },
})
local lifecycle = require("typst.core.lifecycle")
local diagnostics = require("typst.diagnostics")
local fixture_root = vim.fn.tempname()
vim.fn.mkdir(fixture_root, "p")
local transaction_main = fixture_root .. "/main.typ"
vim.fn.writefile({ "= Main" }, transaction_main)
vim.cmd.edit(vim.fn.fnameescape(transaction_main))
vim.bo.filetype = "typst"
local transaction_bufnr = vim.api.nvim_get_current_buf()
local group = ("typst_nvim_buf_%d"):format(transaction_bufnr)

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-attach-transaction-output"),
    project = {
        import_scan = false,
    },
})
local attach_events = 0
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstProjectAttach",
    callback = function()
        attach_events = attach_events + 1
    end,
})
local original_apply = lifecycle.apply_buffer_features
local transaction_ok, transaction_err = xpcall(function()
    rawset(lifecycle, "apply_buffer_features", function()
        error("attach feature boom")
    end)
    local failed = typst.project.attach(transaction_bufnr)
    assert(failed == nil, "failed buffer feature setup should abort attach")
    assert(
        vim.tbl_count(project_store.all()) == 0,
        "failed attach should not commit project registry state"
    )
    assert(
        attach_events == 0,
        "failed attach should not emit TypstProjectAttach"
    )
    assert(
        vim.fn.exists("#" .. group) == 0,
        "failed attach should not leave buffer autocmds"
    )

    local saw_committed_state = false
    rawset(lifecycle, "apply_buffer_features", function(target_bufnr)
        if
            target_bufnr == transaction_bufnr
            and registry.get(transaction_bufnr)
        then
            saw_committed_state = true
        end
        return original_apply(target_bufnr)
    end)
    local first = assert(
        typst.project.attach(transaction_bufnr),
        "attach should succeed after feature setup is restored"
    )
    lifecycle.apply_buffer_features = original_apply
    assert(
        saw_committed_state,
        "buffer features should see committed project state during attach"
    )
    assert(
        vim.tbl_count(project_store.all()) == 1,
        "successful attach should commit one project"
    )
    assert(
        attach_events == 1,
        "successful first attach should emit TypstProjectAttach"
    )

    local second = assert(
        typst.project.attach(transaction_bufnr),
        "reattach should succeed"
    )
    assert(second.key == first.key, "reattach should keep the same project")
    assert(
        attach_events == 1,
        "reattach to the same project should not emit duplicate attach"
    )

    diagnostics.publish(first, "main.typ:1:1: error: detach cleanup")
    local namespace = diagnostics.namespace_for(first)
    assert(
        #vim.diagnostic.get(transaction_bufnr, { namespace = namespace }) == 1,
        "detach fixture should publish diagnostics before detach"
    )
    typst.project.detach(transaction_bufnr)
    assert(
        #vim.diagnostic.get(transaction_bufnr, { namespace = namespace }) == 0,
        "project detach should reset project-owned diagnostic namespaces"
    )
end, debug.traceback)

lifecycle.apply_buffer_features = original_apply

if not transaction_ok then
    error(transaction_err)
end

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("detach-output"),
})
local detach_main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(detach_main)

local detached_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstProjectDetach",
    callback = function(args)
        detached_event = args.data
    end,
})
local detach_project = typst.project.set_main(detach_main)
local live_detach_project = assert(project_store.get(detach_project.key))
local detach_bufnr = vim.api.nvim_get_current_buf()
assert(
    live_detach_project.bufs[detach_bufnr],
    "buffer should be attached before detach"
)
assert(
    typst.ui.status(detach_bufnr).attached,
    "status should report attached buffer before detach"
)

local detached = typst.project.detach(detach_bufnr)
assert(
    detached and detached.key == detach_project.key,
    "detach should return detached project"
)
assert(
    not live_detach_project.bufs[detach_bufnr],
    "detach should remove buffer from project membership"
)
assert(
    project_store.all()[detach_project.key] == nil,
    "empty detached project should be removed from registry"
)
assert(
    not typst.ui.status(detach_bufnr).attached,
    "status should report detached buffer"
)
assert(
    detached_event and detached_event.key == detach_project.key,
    "TypstProjectDetach event was not emitted"
)
assert(typst.project.detach(detach_bufnr) == nil, "detach should be idempotent")

local reattached = typst.project.attach(detach_bufnr)
local live_reattached = assert(project_store.get(reattached.key))
assert(
    reattached and reattached.key == detach_project.key,
    "buffer should reattach after explicit attach"
)
assert(
    live_reattached.bufs[detach_bufnr],
    "reattached project should own the buffer"
)
vim.cmd("bdelete")
assert(
    not live_reattached.bufs[detach_bufnr],
    "BufDelete should detach buffer from project membership"
)
assert(
    project_store.all()[reattached.key] == nil,
    "BufDelete should remove empty project from registry"
)

vim.cmd.edit(detach_main)
local unload_project = typst.project.set_main(detach_main)
local live_unload_project = assert(project_store.get(unload_project.key))
local unload_bufnr = vim.api.nvim_get_current_buf()
vim.cmd("bunload")
assert(
    not live_unload_project.bufs[unload_bufnr],
    "BufUnload should detach buffer from project membership"
)
assert(
    project_store.all()[unload_project.key] == nil,
    "BufUnload should remove empty project from registry"
)

vim.cmd.edit(detach_main)
local wipe_project = typst.project.set_main(detach_main)
local live_wipe_project = assert(project_store.get(wipe_project.key))
local wipe_bufnr = vim.api.nvim_get_current_buf()
vim.cmd("bwipeout")
assert(
    not live_wipe_project.bufs[wipe_bufnr],
    "BufWipeout should detach buffer from project membership"
)
assert(
    project_store.all()[wipe_project.key] == nil,
    "BufWipeout should remove empty project from registry"
)

vim.cmd("qa!")
