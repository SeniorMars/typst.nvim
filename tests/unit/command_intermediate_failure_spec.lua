local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({ completion = { package_cache_prewarm = false } })

vim.cmd.enew()
vim.bo.filetype = "markdown"

local notifications = {}
local original_notify = vim.notify
rawset(vim, "notify", function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end)

local function assert_command_reports_once(command, expected)
    notifications = {}
    local ok, err = pcall(function()
        vim.cmd(command)
    end)
    assert(
        ok,
        command .. " outside a project should not throw: " .. tostring(err)
    )
    assert(
        #notifications == 1,
        command .. " should report the structured failure once"
    )
    assert(
        notifications[1].message:find(expected, 1, true) ~= nil,
        command .. " should surface the no-project reason"
    )
end

assert_command_reports_once("TypstArtifacts", "No Typst project")
assert_command_reports_once("TypstCompile", "No Typst project")
assert_command_reports_once("TypstCompileSS", "No Typst project")
assert_command_reports_once("TypstBibliographyDiagnostics", "no Typst project")
assert_command_reports_once("TypstBibliographyStatus", "no_project")
assert_command_reports_once("TypstCitationOpen", "missing_target")
assert_command_reports_once("TypstCitationPreview", "missing_target")
assert_command_reports_once("TypstCitationRename newkey", "invalid_key")
assert_command_reports_once("TypstPreviewStatus!", "No Typst project")

notifications = {}
local reports = require("typst.ui.reports")
local original_echo_lines = reports.echo_lines
local echoed_lines = {}
rawset(reports, "echo_lines", function(lines)
    echoed_lines[#echoed_lines + 1] = lines
end)

local explain_ok, explain_err = pcall(function()
    vim.cmd("TypstExplainProject")
end)
assert(
    explain_ok,
    "TypstExplainProject outside a project should not throw: "
        .. tostring(explain_err)
)
assert(
    #notifications == 0,
    "TypstExplainProject should not emit a duplicate command failure"
)
assert(
    #echoed_lines == 1
        and echoed_lines[1][1]
        and echoed_lines[1][1]:find("No Typst project", 1, true),
    "TypstExplainProject should print the no-project explanation"
)

notifications = {}
echoed_lines = {}
local project_root = typst_test_cache_path("command-explain-project")
vim.fn.delete(project_root, "rf")
vim.fn.mkdir(project_root, "p")
local main = project_root .. "/main.typ"
vim.fn.writefile({ "= Main" }, main)
vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
vim.cmd("TypstExplainProject")
assert(
    #notifications == 0,
    "successful TypstExplainProject should not emit command notifications"
)
assert(
    #echoed_lines == 1
        and echoed_lines[1][1]
        and echoed_lines[1][1]:find("typst.nvim project explanation", 1, true),
    "successful TypstExplainProject should echo the explanation"
)

rawset(reports, "echo_lines", original_echo_lines)
rawset(vim, "notify", original_notify)

vim.cmd("qa!")
