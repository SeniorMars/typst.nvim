local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")

local notifications = {}
local function capture_notify(message, level)
    notifications[#notifications + 1] = {
        message = tostring(message),
        level = level,
    }
end

local function clear_notifications()
    notifications = {}
end

local function last_notification()
    return notifications[#notifications]
end

local function assert_command_reports(command, expected_message, label)
    clear_notifications()
    local ok, err = pcall(vim.cmd, command)
    assert(ok, label .. " command should not throw: " .. tostring(err))
    local notified = last_notification()
    assert(notified, label .. " command should notify a failure")
    assert(
        notified.message == expected_message,
        ("%s command message mismatch\nexpected: %s\nactual: %s"):format(
            label,
            tostring(expected_message),
            tostring(notified and notified.message)
        )
    )
end

typst.reset({ force = true })
local project_root = typst_test_cache_path("stable-command-api-parity")
vim.fn.delete(project_root, "rf")
vim.fn.mkdir(project_root, "p")
typst.setup({
    root = project_root,
    root_markers = {},
    executable = helpers.fake_typst_sleep(root),
    output_dir = typst_test_cache_path("stable-command-api-parity-output"),
    compile = {
        deps = false,
    },
    completion = {
        package_cache_prewarm = false,
    },
})
require("typst.commands").register(typst, {
    notify = capture_notify,
})

vim.cmd.enew()
local dashboard = vim.api.nvim_get_current_buf()
vim.bo[dashboard].filetype = "markdown"
vim.api.nvim_buf_set_lines(dashboard, 0, -1, false, { "# dashboard" })
vim.api.nvim_set_current_buf(dashboard)

local no_project_value, no_project_err =
    typst.viewer.view({ bufnr = dashboard, notify = false })
assert(
    no_project_value == nil,
    "viewer.view no-project should not return value"
)
assert(
    type(no_project_err) == "table" and no_project_err.reason == "no_project",
    "viewer.view should return structured no_project"
)
assert_command_reports(
    "TypstView",
    no_project_err.message,
    "TypstView no-project"
)

local main = project_root .. "/main.typ"
assert(vim.fn.writefile({ "= Parity" }, main) == 0, "failed to write main")
vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
typst.project.set_main(main)

local missing_output = typst.viewer.view({ notify = false })
assert(
    type(missing_output) == "table"
        and missing_output.ok == false
        and missing_output.reason == "missing_output",
    "viewer.view should return structured missing_output"
)
assert_command_reports(
    "TypstView",
    missing_output.message,
    "TypstView missing-output"
)

local handle = typst.compiler.compile()
assert(handle, "fake compile should return a handle")
local active_clean = typst.viewer.clean({ notify = false })
assert(
    type(active_clean) == "table"
        and active_clean.ok == false
        and active_clean.reason == "active_compiler",
    "viewer.clean should return structured active_compiler"
)
assert_command_reports(
    "TypstClean",
    active_clean.message,
    "TypstClean active-compiler"
)

typst.compiler.stop()
assert(
    vim.wait(10000, function()
        return handle:is_closing()
    end, 20),
    "fake compile did not stop"
)

vim.cmd("qa!")
