local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local project_services = require("typst.project.services")
local typst = require("typst")

local case_id = 0
local original_fake_viewer_log = vim.env.TYPST_NVIM_FAKE_VIEWER_LOG

local function cleanup(group)
    vim.env.TYPST_NVIM_FAKE_VIEWER_LOG = original_fake_viewer_log
    pcall(function()
        typst.reset({ force = true })
    end)
    if group then
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    pcall(vim.cmd, "silent! %bwipeout!")
end

local function run_case(name, fn)
    case_id = case_id + 1
    local group = vim.api.nvim_create_augroup(
        "TypstViewerIntegration" .. case_id,
        { clear = true }
    )

    cleanup(group)
    group = vim.api.nvim_create_augroup(
        "TypstViewerIntegration" .. case_id,
        { clear = true }
    )

    local ok, err = xpcall(function()
        fn(group)
    end, debug.traceback)

    cleanup(group)

    if not ok then
        error(("viewer integration case failed [%s]:\n%s"):format(name, err))
    end
end

local function compile_current_project(message)
    local done = false
    typst.compiler.compile({}, function(result)
        assert(result.code == 0, message)
        done = true
    end)

    assert(
        vim.wait(10000, function()
            return done
        end, 20),
        message
    )
end

local function read_json(path)
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function command_has(command, value)
    for _, arg in ipairs(command or {}) do
        if arg == value then
            return true
        end
    end
    return false
end

local function capture_info()
    local echoed = {}
    local old_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks)
        for _, chunk in ipairs(chunks) do
            echoed[#echoed + 1] = chunk[1]
        end
    end

    local ok, err = xpcall(function()
        typst.ui.info()
    end, debug.traceback)

    vim.api.nvim_echo = old_echo

    if not ok then
        error(err)
    end

    return table.concat(echoed, "\n")
end

run_case("open records callback viewer state", function(group)
    local opened = nil
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-output"),
        viewer = {
            open = function(path)
                opened = path
            end,
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)

    local view_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewOpened",
        callback = function(args)
            view_event = args.data
        end,
    })

    compile_current_project("compile failed before view test")

    project_services.set_viewer(project, {
        backend = "executable",
        command = { "stale-viewer", typst_test_compiler(project).output },
        cwd = "/tmp/stale",
    })

    local viewed = typst.viewer.view()
    assert(
        viewed == typst_test_compiler(project).output,
        "view should return the output path"
    )
    assert(
        opened == typst_test_compiler(project).output,
        "configured viewer did not receive output path"
    )
    assert(
        project_services.viewer(project).backend == "callback",
        "callback viewer should record the current viewer backend"
    )
    assert(
        project_services.viewer(project).command == nil,
        "callback viewer should clear stale viewer command"
    )
    assert(
        project_services.viewer(project).cwd == nil,
        "callback viewer should clear stale viewer cwd"
    )
    assert(view_event, "TypstViewOpened event was not emitted")
    assert(
        view_event.output == typst_test_compiler(project).output,
        "TypstViewOpened event had wrong output"
    )
    assert(view_event.cwd == root, "TypstViewOpened event had wrong cwd")
    assert(
        vim.deep_equal(
            view_event.command,
            typst_test_compiler(project).last_command
        ),
        "TypstViewOpened event had wrong command"
    )
    assert(
        view_event.viewer_backend == "callback",
        "TypstViewOpened should expose callback viewer backend"
    )
    assert(
        view_event.viewer_command == nil,
        "TypstViewOpened should not expose stale viewer command"
    )
    assert(
        view_event.viewer_cwd == nil,
        "TypstViewOpened should not expose stale viewer cwd"
    )
end)

run_case("declined open preserves previous viewer state", function(group)
    local declined = false
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-declined-output"),
        viewer = {
            open = function()
                declined = true
                return false
            end,
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    compile_current_project("compile failed before declined view test")

    project_services.set_viewer(project, {
        provider = "stale-provider",
        backend = "stale-backend",
        command = { "stale-viewer", typst_test_compiler(project).output },
        cwd = "/tmp/stale",
    })

    local view_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewOpened",
        callback = function(args)
            view_event = args.data
        end,
    })

    local declined_result = typst.viewer.view()
    assert(
        declined_result == false,
        "declined viewer callback should be returned"
    )
    assert(declined, "declined viewer callback should run")
    assert(
        project_services.viewer(project).provider == "stale-provider",
        "declined viewer should preserve previous viewer provider"
    )
    assert(
        project_services.viewer(project).backend == "stale-backend",
        "declined viewer should preserve previous viewer backend"
    )
    assert(
        vim.deep_equal(project_services.viewer(project).command, {
            "stale-viewer",
            typst_test_compiler(project).output,
        }),
        "declined viewer should preserve previous viewer command"
    )
    assert(
        project_services.viewer(project).cwd == "/tmp/stale",
        "declined viewer should preserve previous viewer cwd"
    )
    assert(view_event == nil, "declined viewer should not emit TypstViewOpened")
end)

run_case("open failures preserve previous viewer state", function(group)
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-error-output"),
        viewer = {
            open = "__typst_nvim_missing_viewer__",
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    vim.fn.delete(typst_test_compiler(project).output)

    local view_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewOpened",
        callback = function(args)
            view_event = args.data
        end,
    })

    local missing_output_ok, missing_output_err = pcall(function()
        typst.viewer.view()
    end)

    assert(not missing_output_ok, "viewing before output exists should fail")
    assert(
        tostring(missing_output_err):match("output does not exist"),
        tostring(missing_output_err)
    )

    compile_current_project("compile failed before view error test")

    project_services.set_viewer(project, {
        provider = "last-good-provider",
        backend = "last-good-backend",
        command = { "last-good-viewer", typst_test_compiler(project).output },
        cwd = "/tmp/last-good",
    })

    local missing_viewer_ok, missing_viewer_err = pcall(function()
        typst.viewer.view()
    end)

    assert(not missing_viewer_ok, "missing viewer executable should fail")
    assert(
        tostring(missing_viewer_err):match("viewer executable not found"),
        tostring(missing_viewer_err)
    )
    assert(
        view_event == nil,
        "TypstViewOpened should not be emitted when the viewer fails to start"
    )
    assert(
        vim.fn.filereadable(typst_test_compiler(project).output) == 1,
        "view failure should not remove compiled output"
    )
    assert(
        project_services.viewer(project).provider == "last-good-provider",
        "failed viewer open should preserve previous viewer provider"
    )
    assert(
        project_services.viewer(project).backend == "last-good-backend",
        "failed viewer open should preserve previous viewer backend"
    )
    assert(
        vim.deep_equal(project_services.viewer(project).command, {
            "last-good-viewer",
            typst_test_compiler(project).output,
        }),
        "failed viewer open should preserve previous viewer command"
    )
    assert(
        project_services.viewer(project).cwd == "/tmp/last-good",
        "failed viewer open should preserve previous viewer cwd"
    )
end)

run_case("viewer callback errors are isolated", function(group)
    local main = root .. "/tests/fixtures/basic/main.typ"

    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-open-callback-error-output"),
        viewer = {
            open = function()
                error("open exploded")
            end,
        },
    })

    vim.cmd.edit(main)
    local open_project = typst.project.set_main(main)
    compile_current_project(
        "compile failed before view open callback error test"
    )

    local open_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewOpened",
        callback = function(args)
            open_event = args.data
        end,
    })

    project_services.set_viewer(open_project, {
        provider = "stale-provider",
        backend = "stale-backend",
        command = {
            "stale-viewer",
            typst_test_compiler(open_project).output,
        },
        cwd = "/tmp/stale",
    })

    local open_ok, open_err = pcall(function()
        typst.viewer.view()
    end)

    assert(
        not open_ok,
        "viewer open callback errors should fail the view command"
    )
    assert(
        tostring(open_err):match("viewer open callback failed"),
        tostring(open_err)
    )
    assert(
        open_event == nil,
        "failed viewer open callback should not emit TypstViewOpened"
    )
    assert(
        project_services.viewer(open_project).provider == "stale-provider",
        "failed viewer open should preserve previous provider"
    )
    assert(
        project_services.viewer(open_project).backend == "stale-backend",
        "failed viewer open should preserve previous backend"
    )
    assert(
        vim.deep_equal(project_services.viewer(open_project).command, {
            "stale-viewer",
            typst_test_compiler(open_project).output,
        }),
        "failed viewer open should preserve previous command"
    )
    assert(
        project_services.viewer(open_project).cwd == "/tmp/stale",
        "failed viewer open should preserve previous cwd"
    )

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-sync-callback-error-output"),
        viewer = {
            forward = function()
                error("forward exploded")
            end,
            inverse = function()
                error("inverse exploded")
            end,
        },
    })

    vim.cmd.edit(main)
    typst.project.set_main(main)
    compile_current_project(
        "compile failed before view source-sync callback error test"
    )

    local forward_event = nil
    local inverse_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewForwarded",
        callback = function(args)
            forward_event = args.data
        end,
    })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewInverse",
        callback = function(args)
            inverse_event = args.data
        end,
    })

    local forward_result =
        typst.viewer.view_forward({ line = 2, column = 3, notify = false })
    assert(
        forward_result and forward_result.ok == false,
        "failed forward callback should return a failed result"
    )
    assert(
        forward_result.reason == "callback_error",
        "failed forward callback should report callback_error"
    )
    assert(
        forward_result.provider == "generic",
        "failed forward callback should report provider"
    )
    assert(
        forward_event == nil,
        "failed forward callback should not emit TypstViewForwarded"
    )

    local inverse_result = typst.viewer.view_inverse({
        path = main,
        line = 2,
        column = 3,
        notify = false,
    })
    assert(
        inverse_result and inverse_result.ok == false,
        "failed inverse callback should return a failed result"
    )
    assert(
        inverse_result.reason == "callback_error",
        "failed inverse callback should report callback_error"
    )
    assert(
        inverse_result.provider == "generic",
        "failed inverse callback should report provider"
    )
    assert(
        inverse_event == nil,
        "failed inverse callback should not emit TypstViewInverse"
    )
end)

run_case("forward search callback and command", function(group)
    local forwarded_path = nil
    local forwarded_project = nil
    local forwarded_position = nil

    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-forward-output"),
        viewer = {
            forward = function(path, project, position)
                forwarded_path = path
                forwarded_project = project
                forwarded_position = position
                return "forwarded"
            end,
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    compile_current_project("compile failed before view forward test")

    local forward_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewForwarded",
        callback = function(args)
            forward_event = args.data
        end,
    })

    local result = typst.viewer.view_forward({ line = 3, column = 5 })
    assert(result == "forwarded", "view_forward should return callback result")
    assert(
        forwarded_path == typst_test_compiler(project).output,
        "viewer.forward callback should receive output path"
    )
    assert(
        forwarded_project.key == project.key,
        "viewer.forward callback should receive project"
    )
    assert(
        forwarded_position.line == 3,
        "viewer.forward callback should receive line"
    )
    assert(
        forwarded_position.column == 5,
        "viewer.forward callback should receive column"
    )
    assert(forward_event, "TypstViewForwarded event should be emitted")
    assert(
        forward_event.output == typst_test_compiler(project).output,
        "TypstViewForwarded event should include output"
    )
    assert(
        forward_event.line == 3,
        "TypstViewForwarded event should include line"
    )
    assert(
        forward_event.column == 5,
        "TypstViewForwarded event should include column"
    )
    assert(
        forward_event.viewer_backend == "forward-callback",
        "TypstViewForwarded event should include backend"
    )

    vim.api.nvim_win_set_cursor(0, { 3, 4 })
    vim.cmd("TypstViewForward")
    assert(
        forwarded_position.line == 3,
        "TypstViewForward should use cursor line"
    )
    assert(
        forwarded_position.column == 5,
        "TypstViewForward should use 1-based cursor column"
    )
end)

run_case("executable source sync requires declared capability", function()
    local main = root .. "/tests/fixtures/basic/main.typ"
    local chapter = root .. "/tests/fixtures/basic/chapter.typ"
    local log_path = typst_test_cache_path("view-source-sync-gated.json")
    vim.fn.delete(log_path)
    vim.env.TYPST_NVIM_FAKE_VIEWER_LOG = log_path
    local executable = helpers.fake_viewer(root)

    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-source-sync-gated-output"),
        viewer = {
            provider = "custom",
            forward = executable,
            forward_args = {
                "--forward",
                "{source}",
                "{line}",
                "{column}",
                "{output}",
            },
            inverse = executable,
            inverse_args = {
                "--inverse",
                "{source}",
                "{line}",
                "{column}",
                "{output}",
            },
        },
    })

    vim.cmd.edit(main)
    typst.project.set_main(main)
    compile_current_project("compile failed before source-sync gate test")

    local capabilities = typst.viewer.capabilities()
    assert(
        capabilities.configured_forward == true,
        "viewer capabilities should report configured forward command"
    )
    assert(
        capabilities.configured_inverse == true,
        "viewer capabilities should report configured inverse command"
    )
    assert(
        capabilities.forward == false,
        "executable forward should be disabled without source-sync capability"
    )
    assert(
        capabilities.inverse == false,
        "executable inverse should be disabled without source-sync capability"
    )

    local forward =
        typst.viewer.view_forward({ line = 2, column = 3, notify = false })
    assert(
        forward and forward.reason == "unsupported",
        "forward command without source-sync capability should be unsupported"
    )
    assert(
        forward.detail == "capability_required",
        "forward unsupported result should explain the capability gate"
    )

    local inverse = typst.viewer.view_inverse({
        path = chapter,
        line = 4,
        column = 6,
        notify = false,
    })
    assert(
        inverse and inverse.reason == "unsupported",
        "inverse command without source-sync capability should be unsupported"
    )
    assert(
        inverse.detail == "capability_required",
        "inverse unsupported result should explain the capability gate"
    )
    assert(
        vim.fn.filereadable(log_path) == 0,
        "capability-gated source-sync commands should not launch the viewer"
    )

    vim.fn.delete(log_path)
    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-source-sync-enabled-output"),
        viewer = {
            provider = "custom",
            forward = executable,
            forward_args = {
                "--forward",
                "{source}",
                "{line}",
                "{column}",
                "{output}",
            },
            capabilities = {
                forward = true,
            },
        },
    })

    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    compile_current_project("compile failed before source-sync enabled test")

    local enabled = typst.viewer.capabilities()
    assert(
        enabled.forward == true,
        "declared source-sync capability should enable executable forward"
    )

    local enabled_forward =
        typst.viewer.view_forward({ line = 2, column = 3, notify = false })
    assert(
        enabled_forward,
        "forward command with source-sync capability should return a job handle"
    )
    assert(
        vim.wait(10000, function()
            return vim.fn.filereadable(log_path) == 1
        end, 20),
        "source-sync-enabled forward command did not launch the viewer"
    )

    local payload = read_json(log_path)
    assert(
        payload.args[1] == "--forward",
        "viewer forward args should preserve flags"
    )
    assert(
        payload.args[2] == main,
        "viewer forward args should expand source placeholders"
    )
    assert(
        payload.args[3] == "2",
        "viewer forward args should expand line placeholders"
    )
    assert(
        payload.args[4] == "3",
        "viewer forward args should expand column placeholders"
    )
    assert(
        payload.args[5] == typst_test_compiler(project).output,
        "viewer forward args should expand output placeholders"
    )
end)

run_case("inverse source-sync and executable backend", function(group)
    local util = require("typst.core.util")

    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-source-sync-output"),
        viewer = {
            provider = "custom",
            capabilities = {
                inverse = true,
                source_maps = true,
            },
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    local chapter = root .. "/tests/fixtures/basic/chapter.typ"
    vim.cmd.edit(main)
    typst.project.set_main(main)

    local inverse_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewInverse",
        callback = function(args)
            inverse_event = args.data
        end,
    })

    local capabilities = typst.viewer.capabilities()
    assert(
        capabilities.provider == "custom",
        "viewer capabilities should expose selected provider"
    )
    assert(
        capabilities.inverse == true,
        "declared viewer inverse support should be exposed"
    )
    assert(
        capabilities.source_maps == true,
        "declared viewer source-map support should be exposed"
    )
    assert(
        capabilities.configured_inverse == false,
        "source-map default inverse should not require a callback"
    )

    vim.cmd.edit(chapter)
    local inverse = typst.viewer.view_inverse({
        path = main,
        line = 3,
        column = 2,
        notify = false,
    })
    assert(
        inverse and inverse.ok,
        "viewer inverse should jump when source maps are declared"
    )
    assert(inverse.path == main, "viewer inverse should return the source path")
    assert(
        vim.api.nvim_buf_get_name(0) == main,
        "viewer inverse should edit the requested source file"
    )
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert(cursor[1] == 3, "viewer inverse should jump to requested line")
    assert(cursor[2] == 1, "viewer inverse should use 1-based input columns")
    assert(inverse_event, "TypstViewInverse should be emitted")
    assert(
        inverse_event.path == main,
        "viewer inverse event should include source path"
    )
    assert(inverse_event.line == 3, "viewer inverse event should include line")
    assert(
        inverse_event.column == 2,
        "viewer inverse event should include column"
    )
    assert(
        inverse_event.viewer_backend == "inverse-source-map",
        "viewer inverse event should expose backend"
    )

    local main_bufnr = vim.fn.bufnr(main)
    vim.cmd.edit(chapter)
    local original_edit_existing_or_path = util.edit_existing_or_path
    local helper_path = nil
    util.edit_existing_or_path = function(path)
        helper_path = path
        vim.api.nvim_set_current_buf(main_bufnr)
        return main_bufnr
    end

    local ok, err = xpcall(function()
        local reused_inverse = typst.viewer.view_inverse({
            path = main,
            line = 2,
            column = 1,
            notify = false,
        })
        assert(
            reused_inverse and reused_inverse.ok,
            "viewer inverse should succeed through path-identity buffer reuse"
        )
        assert(
            helper_path == main,
            "viewer inverse should route source jumps through the path-identity buffer helper"
        )
        assert(
            vim.api.nvim_get_current_buf() == main_bufnr,
            "viewer inverse should reuse an equivalent loaded source buffer"
        )
    end, debug.traceback)

    util.edit_existing_or_path = original_edit_existing_or_path
    if not ok then
        error(err)
    end

    vim.cmd.edit(chapter)
    vim.cmd(("TypstViewInverse %s 1 1"):format(vim.fn.fnameescape(main)))
    assert(
        vim.api.nvim_buf_get_name(0) == main,
        "TypstViewInverse command should edit the requested source file"
    )

    local log_path = typst_test_cache_path("view-inverse-command.json")
    vim.fn.delete(log_path)
    vim.env.TYPST_NVIM_FAKE_VIEWER_LOG = log_path
    local executable = helpers.fake_viewer(root)

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("view-inverse-command-output"),
        viewer = {
            provider = "custom",
            inverse = executable,
            capabilities = {
                inverse = true,
            },
            inverse_args = {
                "--inverse",
                "{source}",
                "{line}",
                "{column}",
                "{output}",
            },
        },
    })
    vim.cmd.edit(main)
    local command_project = typst.project.set_main(main)

    local command_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewInverse",
        callback = function(args)
            command_event = args.data
        end,
    })

    local command_result = typst.viewer.view_inverse({
        path = chapter,
        line = 4,
        column = 6,
        notify = false,
    })
    assert(
        command_result,
        "viewer inverse executable should return a job handle"
    )
    assert(
        vim.wait(10000, function()
            return vim.fn.filereadable(log_path) == 1
        end, 20),
        "fake inverse viewer did not record invocation"
    )

    local payload = read_json(log_path)
    assert(
        payload.cwd == root,
        "viewer inverse command should run from project root"
    )
    assert(
        payload.args[1] == "--inverse",
        "viewer inverse args should preserve flags"
    )
    assert(
        payload.args[2] == chapter,
        "viewer inverse args should expand source placeholders"
    )
    assert(
        payload.args[3] == "4",
        "viewer inverse args should expand line placeholders"
    )
    assert(
        payload.args[4] == "6",
        "viewer inverse args should expand column placeholders"
    )
    assert(
        payload.args[5] == typst_test_compiler(command_project).output,
        "viewer inverse args should expand output placeholders"
    )
    assert(
        #payload.args == 5,
        "viewer inverse command should not append an extra output argument"
    )
    assert(
        command_event and command_event.viewer_backend == "inverse-executable",
        "viewer inverse command should emit backend"
    )
    assert(
        command_event and command_event.path == chapter,
        "viewer inverse command event should include source path"
    )
end)

run_case("executable viewer args and info reporting", function(group)
    local log_path = typst_test_cache_path("viewer-args.json")
    vim.fn.delete(log_path)
    vim.env.TYPST_NVIM_FAKE_VIEWER_LOG = log_path
    local executable = helpers.fake_viewer(root)

    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("viewer-args-output"),
        viewer = {
            open = executable,
            args = {
                "--reuse-instance",
                "--file={output}",
                "--mode",
                "presentation",
            },
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    compile_current_project("compile failed before viewer args test")

    local view_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewOpened",
        callback = function(args)
            view_event = args.data
        end,
    })

    typst.viewer.view()

    assert(
        vim.wait(10000, function()
            return vim.fn.filereadable(log_path) == 1
        end, 20),
        "fake viewer did not record invocation"
    )

    local payload = read_json(log_path)
    assert(payload.cwd == root, "viewer command should run from project root")
    assert(
        payload.args[1] == "--reuse-instance",
        "viewer args should preserve configured flags"
    )
    assert(
        payload.args[2] == "--file=" .. typst_test_compiler(project).output,
        "viewer args should expand {output} placeholder"
    )
    assert(
        payload.args[3] == "--mode",
        "viewer args should preserve trailing flags"
    )
    assert(
        payload.args[4] == "presentation",
        "viewer args should preserve trailing values"
    )
    assert(
        #payload.args == 4,
        "viewer should not append output when {output} is present"
    )

    local viewer_state = project_services.viewer(project)
    assert(viewer_state.cwd == root, "project should record viewer cwd")
    assert(
        viewer_state.backend == "executable",
        "project should record executable viewer backend"
    )
    local expected_command = vim.list_extend(vim.deepcopy(executable), {
        "--reuse-instance",
        "--file=" .. typst_test_compiler(project).output,
        "--mode",
        "presentation",
    })
    assert(
        vim.deep_equal(viewer_state.command, expected_command),
        "project should record the expanded viewer command"
    )
    assert(
        view_event and view_event.viewer_cwd == root,
        "view event should include viewer cwd"
    )
    assert(
        view_event and view_event.viewer_backend == "executable",
        "view event should include viewer backend"
    )
    assert(
        vim.deep_equal(view_event.viewer_command, viewer_state.command),
        "view event should include viewer command"
    )

    local text = capture_info()
    assert(
        text:find("viewer backend:%s+executable"),
        "TypstInfo should show viewer backend"
    )
    assert(
        text:find("viewer command:.*fake%-viewer%.py"),
        "TypstInfo should show viewer command"
    )
    assert(
        text:find("viewer cwd:%s+" .. vim.pesc(root)),
        "TypstInfo should show viewer cwd"
    )
end)

run_case("viewer provider preset capabilities and state", function(group)
    local log_path = typst_test_cache_path("viewer-provider.json")
    vim.fn.delete(log_path)
    vim.env.TYPST_NVIM_FAKE_VIEWER_LOG = log_path
    local executable = helpers.fake_viewer(root)

    local viewer = require("typst.viewer")
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("viewer-provider-output"),
        viewer = {
            provider = "zathura",
            providers = {
                zathura = {
                    open = executable,
                },
            },
        },
    })

    local capabilities = viewer.capabilities()
    assert(
        capabilities.provider == "zathura",
        "viewer capabilities should expose the selected provider"
    )
    assert(
        capabilities.forward == false,
        "pdf viewer presets should not claim forward support by default"
    )
    assert(
        capabilities.inverse == false,
        "pdf viewer presets should not claim inverse support by default"
    )

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    compile_current_project("compile failed before viewer provider test")

    local view_event = nil
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstViewOpened",
        callback = function(args)
            view_event = args.data
        end,
    })

    typst.viewer.view()
    assert(
        vim.wait(10000, function()
            return vim.fn.filereadable(log_path) == 1
        end, 20),
        "fake provider viewer did not record invocation"
    )

    local payload = read_json(log_path)
    assert(
        payload.args[1] == "--reuse-instance",
        "zathura preset should include reuse-instance"
    )
    assert(
        payload.args[2] == typst_test_compiler(project).output,
        "zathura preset should pass the output path"
    )
    assert(
        project_services.viewer(project).provider == "zathura",
        "project should record the selected viewer provider"
    )
    assert(
        project_services.viewer(project).backend == "zathura",
        "project should record provider backend"
    )
    assert(
        view_event and view_event.viewer_provider == "zathura",
        "view event should include viewer provider"
    )

    local status = typst.ui.status()
    assert(
        status.viewer_provider == "zathura",
        "status should include viewer provider"
    )
    assert(
        status.viewer_backend == "zathura",
        "status should include provider backend"
    )

    local text = capture_info()
    assert(
        text:find("viewer provider:%s+zathura"),
        "TypstInfo should show viewer provider"
    )
    assert(
        text:find("viewer backend:%s+zathura"),
        "TypstInfo should show provider backend"
    )

    local forward =
        typst.viewer.view_forward({ line = 3, column = 5, notify = false })
    assert(
        forward and forward.reason == "unsupported",
        "provider forward should be capability-gated"
    )
    assert(
        forward.provider == "zathura",
        "unsupported forward result should include provider"
    )
    assert(
        forward.capabilities.forward == false,
        "unsupported forward result should include capabilities"
    )
end)

run_case("compile opens viewer and notifies reload consumers", function()
    local viewer_log = typst_test_cache_path("compile-viewer-open.json")
    vim.fn.delete(viewer_log)
    vim.env.TYPST_NVIM_FAKE_VIEWER_LOG = viewer_log

    local reloads = {}
    local refreshes = {}

    typst.setup({
        root = root,
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-cycles.py"
        ),
        output_dir = typst_test_cache_path("compile-viewer-output"),
        compile = {
            deps = false,
            open = true,
        },
        viewer = {
            provider = "zathura",
            reload = function(project, result, opts)
                reloads[#reloads + 1] = {
                    key = project.key,
                    code = result.code,
                    source = opts and opts.source,
                    watch = opts and opts.watch,
                }
                return true
            end,
            providers = {
                zathura = {
                    open = helpers.fake_viewer(root),
                },
            },
        },
        preview = {
            refresh = function(project, result, opts)
                refreshes[#refreshes + 1] = {
                    key = project.key,
                    code = result.code,
                    source = opts and opts.source,
                    watch = opts and opts.watch,
                }
                return true
            end,
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)

    local done = false
    typst.compiler.compile({}, function(result)
        assert(result.code == 0, "compile with viewer open failed")
        done = true
    end)

    assert(
        vim.wait(10000, function()
            return done and vim.fn.filereadable(viewer_log) == 1
        end, 20),
        "compile.open did not open the configured viewer"
    )

    local viewer_payload = read_json(viewer_log)
    assert(
        viewer_payload.args[2] == typst_test_compiler(project).output,
        "viewer open should receive the compiler output path"
    )
    assert(
        not command_has(typst_test_compiler(project).last_command, "--open"),
        "compile.open should not pass --open to the Typst CLI"
    )
    assert(
        reloads[1]
            and reloads[1].code == 0
            and reloads[1].source == "compile"
            and reloads[1].watch == false,
        "compile success should notify viewer reload callbacks: "
            .. vim.inspect(reloads)
    )
    assert(
        refreshes[1]
            and refreshes[1].code == 0
            and refreshes[1].source == "compile"
            and refreshes[1].watch == false,
        "compile success should notify preview refresh callbacks"
    )

    typst.reset()
    vim.fn.delete(viewer_log)

    typst.setup({
        root = root,
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-cycles.py"
        ),
        output_dir = typst_test_cache_path("compile-typst-open-output"),
        compile = {
            deps = false,
            typst_open = true,
        },
    })

    vim.cmd.edit(main)
    project = typst.project.set_main(main)

    done = false
    typst.compiler.compile({}, function(result)
        assert(result.code == 0, "compile with typst_open failed")
        done = true
    end)

    assert(
        vim.wait(10000, function()
            return done
        end, 20),
        "compile with typst_open did not finish"
    )
    assert(
        command_has(typst_test_compiler(project).last_command, "--open"),
        "compile.typst_open should pass --open to the Typst CLI"
    )
    assert(
        vim.fn.filereadable(viewer_log) == 0,
        "compile.typst_open should not open the typst.nvim viewer"
    )
end)

run_case("watch opens viewer and notifies reload consumers", function()
    local viewer_log = typst_test_cache_path("watch-viewer-open.json")
    vim.fn.delete(viewer_log)
    vim.env.TYPST_NVIM_FAKE_VIEWER_LOG = viewer_log

    local reloads = {}
    local refreshes = {}
    local callbacks = {}

    typst.setup({
        root = root,
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-watch-cycles.py"
        ),
        output_dir = typst_test_cache_path("watch-viewer-output"),
        compile = {
            deps = false,
            open = true,
        },
        viewer = {
            provider = "zathura",
            reload = function(project, result, opts)
                reloads[#reloads + 1] = {
                    key = project.key,
                    code = result.code,
                    source = opts and opts.source,
                    watch = opts and opts.watch,
                }
                return true
            end,
            providers = {
                zathura = {
                    open = helpers.fake_viewer(root),
                },
            },
        },
        preview = {
            refresh = function(project, result, opts)
                refreshes[#refreshes + 1] = {
                    key = project.key,
                    code = result.code,
                    source = opts and opts.source,
                    watch = opts and opts.watch,
                }
                return true
            end,
        },
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)

    typst.compiler.watch({}, function(result)
        callbacks[#callbacks + 1] = {
            code = result.code,
            cycle = result.cycle,
        }
    end)

    assert(
        vim.wait(10000, function()
            return #callbacks >= 3
                and #reloads >= 3
                and #refreshes >= 3
                and vim.fn.filereadable(viewer_log) == 1
        end, 20),
        "watch did not open viewer and notify reload/refresh callbacks"
    )

    local viewer_payload = read_json(viewer_log)
    assert(
        viewer_payload.args[2] == typst_test_compiler(project).output,
        "watch viewer open should receive the compiler output path"
    )
    assert(
        not command_has(typst_test_compiler(project).last_command, "--open"),
        "compile.open should not pass --open to typst watch"
    )
    assert(
        reloads[1].source == "watch" and reloads[1].watch == true,
        "watch reload callbacks should identify watch source"
    )
    assert(
        refreshes[2].code == 1
            and refreshes[2].source == "watch"
            and refreshes[2].watch == true,
        "watch preview refresh should still receive failed cycle payloads"
    )

    typst.compiler.stop()
    assert(
        vim.wait(10000, function()
            return typst_test_compiler(project).watcher == nil
        end, 20),
        "watcher did not stop after viewer consumer test"
    )
end)

vim.cmd("qa!")
