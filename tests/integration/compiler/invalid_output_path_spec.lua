local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local project_store = require("typst.project.store")
local output_ownership = require("typst.resources.outputs")

local function cleanup(group)
    pcall(function()
        typst.reset({ force = true })
    end)
    if group then
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local function setup_project()
    cleanup()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("invalid-output-path-output"),
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local snapshot = typst.project.set_main(main)
    return assert(project_store.get(snapshot.key), "live project")
end

local function active_leases(project)
    return vim.tbl_count(output_ownership.active_for_project(project))
end

local function assert_invalid_output_result(result, label)
    assert(type(result) == "table", label .. " should return a result table")
    assert(
        result.ok == false and result.code == 1,
        label .. " should report failure"
    )
    assert(
        result.reason == "output_path_invalid",
        label .. " should report output_path_invalid"
    )
    assert(
        tostring(result.message or ""):find("Invalid Typst", 1, true),
        label .. " should include a friendly message"
    )
    assert(
        not tostring(result.message or ""):find("stack traceback", 1, true),
        label .. " should not expose a traceback in the user message"
    )
end

local group =
    vim.api.nvim_create_augroup("TypstInvalidOutputPathSpec", { clear = true })

local ok, err = xpcall(function()
    cleanup()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("invalid-output-path-output"),
        output_name = "bad/name",
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local attach_ok, attach_snapshot = pcall(function()
        return typst.project.set_main(main)
    end)
    assert(attach_ok, "invalid output config should not make attach throw")
    assert(type(attach_snapshot) == "table", "attach should return a snapshot")
    local attach_project =
        assert(project_store.get(attach_snapshot.key), "attached project")
    assert(
        typst_test_compiler(attach_project).output == nil,
        "invalid planned output should not be stored during attach"
    )

    local compile_project = setup_project()
    local compile_started = 0
    local compile_failed = 0
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStarted",
        callback = function()
            compile_started = compile_started + 1
        end,
    })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileFailed",
        callback = function()
            compile_failed = compile_failed + 1
        end,
    })

    require("typst.config").unsafe_get().output_name = "bad/name"
    local compile_callbacks = 0
    local compile_callback_result = nil
    local compile_result = typst.compiler.compile({}, function(result)
        compile_callbacks = compile_callbacks + 1
        compile_callback_result = result
    end)

    assert_invalid_output_result(compile_result, "compile")
    assert(
        compile_callback_result == compile_result,
        "compile callback should receive the returned failure"
    )
    assert(compile_callbacks == 1, "compile callback should run once")
    assert(compile_started == 0, "invalid compile should not emit started")
    assert(compile_failed == 1, "invalid compile should emit failed")
    assert(
        typst_test_compiler(compile_project).process == nil,
        "invalid compile should not store a process"
    )
    assert(
        active_leases(compile_project) == 0,
        "invalid compile should not leave an output lease"
    )

    local watch_project = setup_project()
    local watch_started = 0
    local watch_failed = 0
    vim.api.nvim_clear_autocmds({ group = group })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileStarted",
        callback = function()
            watch_started = watch_started + 1
        end,
    })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstCompileFailed",
        callback = function()
            watch_failed = watch_failed + 1
        end,
    })

    require("typst.config").unsafe_get().output_name = "bad/name"
    local watch_callbacks = 0
    local watch_callback_result = nil
    local watch_result = typst.compiler.watch({}, function(result)
        watch_callbacks = watch_callbacks + 1
        watch_callback_result = result
    end)

    assert_invalid_output_result(watch_result, "watch")
    assert(
        watch_callback_result == watch_result,
        "watch callback should receive the returned failure"
    )
    assert(watch_callbacks == 1, "watch callback should run once")
    assert(watch_started == 0, "invalid watch should not emit started")
    assert(watch_failed == 1, "invalid watch should emit failed")
    assert(
        typst_test_compiler(watch_project).watcher == nil,
        "invalid watch should not store a watcher"
    )
    assert(
        active_leases(watch_project) == 0,
        "invalid watch should not leave an output lease"
    )
end, debug.traceback)

cleanup(group)

if not ok then
    error(err)
end

vim.cmd("qa!")
