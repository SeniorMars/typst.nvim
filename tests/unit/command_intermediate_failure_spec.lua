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

rawset(vim, "notify", original_notify)

vim.cmd("qa!")
