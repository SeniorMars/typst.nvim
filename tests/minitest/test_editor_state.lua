local MiniTest = require("mini.test")

local helpers = require("tests.minitest.helpers")

local T = MiniTest.new_set()

local function target_window_contract()
    local root = vim.fn.getcwd()

    local project_services = require("typst.project.services")
    local typst = require("typst")

    typst.reset()

    local forwarded = nil
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("target-window-output"),
        viewer = {
            provider = "custom",
            forward = function(_, _, position)
                forwarded = position
                return "forwarded"
            end,
            capabilities = {
                inverse = true,
                source_maps = true,
            },
        },
        preview = {
            capabilities = {
                inverse = true,
                source_maps = true,
            },
        },
    })
    local fixture_dir = typst_test_root_path("fixtures/target-window-contract")
    vim.fn.mkdir(fixture_dir, "p")
    local main = fixture_dir .. "/main.typ"
    local target = fixture_dir .. "/target.typ"
    local output = typst_test_cache_path("target-window-output/main.pdf")
    vim.fn.writefile({ '#import "target.typ": target', "target()" }, main)
    vim.fn.writefile({ "#let target() = [ok]" }, target)
    vim.fn.mkdir(vim.fs.dirname(output), "p")
    vim.fn.writefile({ "%PDF-1.7" }, output)

    vim.cmd.edit(main)
    vim.bo.filetype = "typst"
    local source_win = vim.api.nvim_get_current_win()
    local source_buf = vim.api.nvim_get_current_buf()
    local project = typst.project.set_main(main)
    project_services.set_compiler(project, { output = output })
    local source_line = vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1]
    local target_col = assert(source_line:find("target.typ", 1, true)) - 1

    vim.cmd("botright split")
    local default_dest_win = vim.api.nvim_get_current_win()
    vim.cmd.enew()
    local default_dest_buf = vim.api.nvim_get_current_buf()

    local followed = typst.navigation.follow({
        bufnr = source_buf,
        pos = { 0, target_col },
    })
    assert(
        followed and followed.path == target,
        "follow should resolve source buffer context"
    )
    assert(
        vim.api.nvim_get_current_win() == default_dest_win,
        "follow should open in the current destination window by default"
    )
    assert(
        vim.api.nvim_win_get_buf(default_dest_win) ~= source_buf,
        "default destination should not be forced to the source buffer"
    )
    assert(
        vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(default_dest_win))
            == target,
        "default destination window should receive the followed file"
    )
    assert(
        vim.api.nvim_win_get_buf(source_win) == source_buf,
        "source window should keep displaying the source buffer"
    )

    vim.cmd("botright split")
    local explicit_dest_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(explicit_dest_win, default_dest_buf)
    vim.api.nvim_set_current_win(default_dest_win)

    local explicit_follow = typst.navigation.follow({
        bufnr = source_buf,
        pos = { 0, target_col },
        open_winid = explicit_dest_win,
    })
    assert(
        explicit_follow and explicit_follow.path == target,
        "follow should still resolve from the source buffer with open_winid"
    )
    assert(
        vim.api.nvim_get_current_win() == explicit_dest_win,
        "follow should focus the explicit destination window"
    )
    assert(
        vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(explicit_dest_win))
            == target,
        "follow should open file targets in opts.open_winid"
    )

    local context_actions = require("typst.context").open({
        bufnr = source_buf,
        pos = { 0, target_col },
        open = false,
    })
    local follow_action = nil
    for _, action in ipairs(context_actions) do
        if action.id == "follow" then
            follow_action = action
            break
        end
    end
    assert(
        follow_action,
        "context actions should include follow for path targets"
    )

    vim.api.nvim_win_set_buf(default_dest_win, default_dest_buf)
    require("typst.context").execute(follow_action, {
        open_winid = default_dest_win,
    })
    assert(
        vim.api.nvim_get_current_win() == default_dest_win,
        "context follow action should focus opts.open_winid"
    )
    assert(
        vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(default_dest_win))
            == target,
        "context follow action should pass opts.open_winid to navigation"
    )

    vim.api.nvim_win_set_buf(default_dest_win, default_dest_buf)
    local inverse = typst.viewer.view_inverse({
        bufnr = source_buf,
        path = main,
        line = 2,
        column = 1,
        open_winid = default_dest_win,
        notify = false,
    })
    assert(inverse and inverse.ok, "viewer inverse should open source maps")
    assert(
        vim.api.nvim_get_current_win() == default_dest_win,
        "viewer inverse should focus opts.open_winid"
    )
    assert(
        vim.api.nvim_win_get_buf(default_dest_win) == source_buf,
        "viewer inverse should display the requested source in opts.open_winid"
    )
    assert(
        vim.api.nvim_win_get_cursor(default_dest_win)[1] == 2,
        "viewer inverse should set cursor in opts.open_winid"
    )

    vim.api.nvim_win_set_buf(default_dest_win, default_dest_buf)
    local preview_inverse = typst.viewer.preview_inverse({
        bufnr = source_buf,
        path = main,
        line = 1,
        column = 1,
        open_winid = default_dest_win,
        notify = false,
    })
    assert(
        preview_inverse and preview_inverse.path == main,
        "preview inverse should open source maps"
    )
    assert(
        vim.api.nvim_get_current_win() == default_dest_win,
        "preview inverse should focus opts.open_winid"
    )
    assert(
        vim.api.nvim_win_get_buf(default_dest_win) == source_buf,
        "preview inverse should display the requested source in opts.open_winid"
    )

    vim.api.nvim_win_set_buf(default_dest_win, default_dest_buf)
    vim.api.nvim_set_current_win(default_dest_win)
    local missing_position = typst.viewer.view_forward({
        bufnr = source_buf,
        notify = false,
    })
    assert(
        missing_position
            and missing_position.ok == false
            and missing_position.reason == "position_required",
        "viewer forward should not use the current window for explicit non-current buffers"
    )

    local forwarded_result = typst.viewer.view_forward({
        bufnr = source_buf,
        winid = source_win,
        notify = false,
    })
    assert(
        forwarded_result == "forwarded",
        "viewer forward should accept source winid"
    )
    assert(
        forwarded and forwarded.line == 1,
        "viewer forward should read cursor position from opts.winid"
    )
end

local function ui_open_contract()
    local root = vim.fn.getcwd()

    local artifacts = require("typst.workflows.artifacts")
    local open_helper = require("typst.core.open")
    local typst = require("typst")
    local viewer = require("typst.viewer.generic")

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("ui-open-output"),
        completion = {
            package_cache_prewarm = false,
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    local output = typst_test_cache_path("ui-open-output/main.pdf")
    vim.fn.mkdir(vim.fs.dirname(output), "p")
    vim.fn.writefile({ "pdf" }, output)
    typst_test_compiler(project).output = output

    local original_open = vim.ui.open
    local original_executable = vim.fn.executable
    local original_jobstart = vim.fn.jobstart
    local open_calls = 0
    local ok, err = xpcall(function()
        rawset(vim.ui, "open", function()
            open_calls = open_calls + 1
            return nil, "ui open failed"
        end)
        local object, open_err = open_helper.ui_open(output)
        assert(
            object == nil and open_err == "ui open failed",
            "open helper should expose vim.ui.open return errors"
        )

        local viewer_ok, viewer_err = pcall(viewer.open, project)
        assert(
            not viewer_ok,
            "viewer should fail when vim.ui.open reports failure"
        )
        assert(
            tostring(viewer_err):find("ui open failed", 1, true),
            "viewer failure should include vim.ui.open error"
        )

        local artifact = typst_test_cache_path("ui-open-output/artifact.pdf")
        vim.fn.writefile({ "artifact" }, artifact)
        ---@type any
        local result = artifacts.open(project, {
            path = artifact,
        })
        assert(
            result.ok,
            "artifact open should fall back to editing when vim.ui.open fails"
        )
        assert(
            vim.api.nvim_buf_get_name(0) == artifact,
            "artifact open fallback should edit the artifact instead of reporting vim.ui.open success"
        )
        assert(
            open_calls >= 3,
            "ui.open should be exercised by helper, viewer, and artifact paths"
        )

        rawset(vim.ui, "open", function(target)
            return {
                target = target,
            }
        end)
        local opened = open_helper.url("https://example.com")
        assert(
            opened and opened.provider == "vim.ui.open",
            "URL open should prefer vim.ui.open"
        )

        local jobs = {}
        vim.ui.open = nil
        rawset(vim.fn, "executable", function(command)
            return command == "xdg-open" and 1 or 0
        end)
        rawset(vim.fn, "jobstart", function(command, opts)
            jobs[#jobs + 1] = { command = command, opts = opts }
            return 42
        end)
        opened = open_helper.url("https://example.com/fallback", {
            commands = {
                { "missing-open", "https://example.com/fallback" },
                { "xdg-open", "https://example.com/fallback" },
            },
        })
        assert(
            opened and opened.provider == "xdg-open" and opened.job == 42,
            "URL open should use the first available platform fallback"
        )
        assert(
            jobs[1]
                and jobs[1].opts
                and jobs[1].opts.detach == true
                and jobs[1].command[1] == "xdg-open",
            "URL fallback should start detached opener jobs"
        )

        assert(
            open_helper.browser_commands(
                "default",
                "https://example.com/browser"
            ) == nil,
            "default browser selector should keep OS opener behavior"
        )
        local browser_commands = open_helper.browser_commands(
            "firefox",
            "https://example.com/browser"
        )
        assert(
            type(browser_commands) == "table" and #browser_commands >= 1,
            "named browser selector should produce opener candidates"
        )
        local has_browser_url = false
        for _, command in ipairs(browser_commands) do
            for _, arg in ipairs(command) do
                if arg == "https://example.com/browser" then
                    has_browser_url = true
                end
            end
        end
        assert(
            has_browser_url,
            "named browser opener commands should include the URL"
        )

        rawset(vim.fn, "executable", function()
            return 0
        end)
        local failed, failed_err = open_helper.url("https://example.com/none", {
            ui = false,
            commands = {
                { "missing-open", "https://example.com/none" },
            },
        })
        assert(
            failed == nil
                and tostring(failed_err):find("executable not found", 1, true),
            "URL open should report failure when no opener is available"
        )
    end, debug.traceback)

    vim.ui.open = original_open
    vim.fn.executable = original_executable
    vim.fn.jobstart = original_jobstart

    if not ok then
        error(err)
    end
end

T["routes file/context/viewer actions to target windows"] = function()
    helpers.start_child().lua_func(target_window_contract)
end

T["handles vim.ui.open and URL fallback behavior"] = function()
    helpers.start_child().lua_func(ui_open_contract)
end

return T
