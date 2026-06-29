local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local registry = require("typst.project")
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

vim.cmd.edit(chapter)
local bufnr = vim.api.nvim_get_current_buf()
local standalone = typst.project.get(bufnr)
assert(
    standalone.main == chapter,
    "chapter should start as a standalone project"
)
assert(
    standalone.bufs[bufnr],
    "standalone project should own the current buffer"
)

local project = typst.project.set_main(main)

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
    registry.all()[standalone.key] == nil,
    "empty old project should be removed after TypstSetMain"
)

local same = typst.project.get(0)
assert(same.key == project.key, "buffer should keep the same project key")

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
    lifecycle.apply_buffer_features = function()
        error("attach feature boom")
    end

    local failed = typst.project.attach(transaction_bufnr)
    assert(failed == nil, "failed buffer feature setup should abort attach")
    assert(
        vim.tbl_count(registry.all()) == 0,
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
    lifecycle.apply_buffer_features = function(target_bufnr)
        if
            target_bufnr == transaction_bufnr
            and registry.get(transaction_bufnr)
        then
            saw_committed_state = true
        end
        return original_apply(target_bufnr)
    end
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
        vim.tbl_count(registry.all()) == 1,
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
local detach_bufnr = vim.api.nvim_get_current_buf()
assert(
    detach_project.bufs[detach_bufnr],
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
    not detach_project.bufs[detach_bufnr],
    "detach should remove buffer from project membership"
)
assert(
    registry.all()[detach_project.key] == nil,
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
assert(
    reattached and reattached.key == detach_project.key,
    "buffer should reattach after explicit attach"
)
assert(
    reattached.bufs[detach_bufnr],
    "reattached project should own the buffer"
)
vim.cmd("bdelete")
assert(
    not reattached.bufs[detach_bufnr],
    "BufDelete should detach buffer from project membership"
)
assert(
    registry.all()[reattached.key] == nil,
    "BufDelete should remove empty project from registry"
)

vim.cmd.edit(detach_main)
local unload_project = typst.project.set_main(detach_main)
local unload_bufnr = vim.api.nvim_get_current_buf()
vim.cmd("bunload")
assert(
    not unload_project.bufs[unload_bufnr],
    "BufUnload should detach buffer from project membership"
)
assert(
    registry.all()[unload_project.key] == nil,
    "BufUnload should remove empty project from registry"
)

vim.cmd.edit(detach_main)
local wipe_project = typst.project.set_main(detach_main)
local wipe_bufnr = vim.api.nvim_get_current_buf()
vim.cmd("bwipeout")
assert(
    not wipe_project.bufs[wipe_bufnr],
    "BufWipeout should detach buffer from project membership"
)
assert(
    registry.all()[wipe_project.key] == nil,
    "BufWipeout should remove empty project from registry"
)

vim.cmd("qa!")
