local contract = require("tests.helpers.api_contract")
local root, typst = contract.setup()

local public_commands = {
    "TypstInfo",
    "TypstReloadState",
    "TypstClearCache",
    "TypstLocks",
    "TypstCleanLocks",
    "TypstSetMain",
    "TypstToggleMain",
    "TypstEditMain",
    "TypstFiles",
    "TypstCd",
    "TypstCompile",
    "TypstCompileSS",
    "TypstCompileSelected",
    "TypstCompileOutput",
    "TypstWatch",
    "TypstStop",
    "TypstStopAll",
    "TypstCompilerForceClear",
    "TypstStatus",
    "TypstStatusAll",
    "TypstCount",
    "TypstFormat",
    "TypstLint",
    "TypstGrammar",
    "TypstFontDiagnostics",
    "TypstView",
    "TypstViewForward",
    "TypstViewInverse",
    "TypstClean",
    "TypstExport",
    "TypstArtifacts",
    "TypstArtifactOpen",
    "TypstArtifactClean",
    "TypstEval",
    "TypstEvalSelection",
    "TypstInspect",
    "TypstInit",
    "TypstTemplates",
    "TypstProfile",
    "TypstTest",
    "TypstBench",
    "TypstCoverage",
    "TypstInlayHintsToggle",
    "TypstCodeAction",
    "TypstColorInfo",
    "TypstColorPresentation",
    "TypstLinks",
    "TypstCodeLens",
    "TypstWorkspaceSymbols",
    "TypstReferences",
    "TypstRenamePreview",
    "TypstSelectionExpand",
    "TypstOnEnter",
    "TypstHtmlPreview",
    "TypstPresentation",
    "TypstPreview",
    "TypstPreviewInverse",
    "TypstPreviewStop",
    "TypstPreviewToggle",
    "TypstPreviewFragment",
    "TypstPreviewEquation",
    "TypstPreviewImage",
    "TypstPreviewPage",
    "TypstRenderCacheClear",
    "TypstToc",
    "TypstTocOpen",
    "TypstTocRefresh",
    "TypstTocToggle",
    "TypstLabels",
    "TypstCitations",
    "TypstCitationInsert",
    "TypstCitationSearch",
    "TypstCitationOpen",
    "TypstCitationPreview",
    "TypstCitationRename",
    "TypstBibliographyStatus",
    "TypstBibliographyDiagnostics",
    "TypstBibliographyAttachments",
    "TypstSymbols",
    "TypstPick",
    "TypstFollow",
    "TypstContextMenu",
    "TypstDiagnostics",
    "TypstErrors",
    "TypstConcealEnable",
    "TypstConcealDisable",
    "TypstConcealToggle",
    "TypstConcealRefresh",
    "TypstConcealInspect",
    "TypstPackageInfo",
    "TypstPackageOpen",
    "TypstPackageReadme",
    "TypstPackageSource",
    "TypstSymbolInfo",
    "TypstSymbolVariants",
    "TypstPromoteHeading",
    "TypstDemoteHeading",
    "TypstRefreshFolds",
    "TypstMatchHighlightEnable",
    "TypstMatchHighlightDisable",
    "TypstMatchHighlightToggle",
    "TypstMatchHighlightRefresh",
    "TypstUnwrapFunction",
    "TypstChangeFunction",
    "TypstSurroundDeleteCall",
    "TypstSurroundChangeCall",
    "TypstChangeDelimiter",
    "TypstSurroundDeleteDelimiter",
    "TypstSurroundChangeDelimiter",
    "TypstSurroundDeleteBlock",
    "TypstSurroundChangeBlock",
    "TypstSurroundDeleteEquation",
    "TypstSurroundChangeEquation",
    "TypstSplitArguments",
    "TypstJoinArguments",
    "TypstToggleArguments",
    "TypstNameArguments",
    "TypstToggleTrailingComma",
    "TypstAddTrailingComma",
    "TypstRemoveTrailingComma",
    "TypstToggleLabel",
    "TypstToggleReference",
    "TypstToggleLabelReference",
    "TypstSurround",
    "TypstSurroundFunction",
    "TypstSurroundContent",
    "TypstSurroundEquation",
    "TypstSurroundFigure",
    "TypstSurroundBlock",
    "TypstSurroundStrong",
    "TypstSurroundEmph",
    "TypstInsert",
    "TypstImapsList",
    "TypstToggleStrong",
    "TypstToggleEmph",
    "TypstToggleFigure",
    "TypstToggleList",
    "TypstToggleBulletList",
    "TypstToggleNumberedList",
    "TypstConvertEquation",
    "TypstToggleEquationNumbering",
    "TypstToggleFraction",
    "TypstToggleDelimiterSize",
    "TypstToggleLineBreak",
    "TypstCreateFunction",
    "TypstSmartClose",
    "TypstConvertRaw",
    "TypstDoctor",
    "TypstLog",
}

for _, name in ipairs(public_commands) do
    assert(
        vim.fn.exists(":" .. name) == 2,
        ("missing public command: %s"):format(name)
    )
end

local registered_user_commands = vim.api.nvim_get_commands({ builtin = false })
for _, name in ipairs({
    "TypstDoc",
    "TypstDocSymbol",
    "TypstDocSearch",
    "TypstDocPackage",
    "TypstDocSource",
    "TypstDocOnline",
}) do
    assert(
        registered_user_commands[name] == nil,
        ("removed TypstDoc command should stay absent: %s"):format(name)
    )
end

local command_util = require("typst.ui.commands.util")
local notified = nil
local old_notify = vim.notify
vim.notify = function(message, level, opts)
    notified = {
        message = message,
        level = level,
        opts = opts,
    }
end

local command_name = "TypstBoundaryBoomTest"
command_util.create(command_name, function()
    error("typst.nvim: expected command failure")
end, {
    desc = "test command error boundary",
})

local command_ok = pcall(vim.cmd, command_name)
vim.notify = old_notify

assert(command_ok, "command error boundary should prevent raw command errors")
assert(notified, "command failure should notify the user")
assert(
    notified.level == vim.log.levels.ERROR,
    "command failure notification should be an error"
)
assert(
    notified.message:match("expected command failure"),
    "command failure notification should include the concise plugin error"
)

local logged = false
for _, entry in ipairs(typst.ui.log()) do
    if
        entry.message == "command failed"
        and entry.fields
        and entry.fields.command == command_name
    then
        logged = true
        break
    end
end
assert(logged, "command failure should be logged with the command name")

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
typst.project.set_main(main)
local attached_project = typst.project.get()

local saved = {
    debug = typst.debug,
    ui = typst.ui,
    project = typst.project,
    navigation = typst.navigation,
}

local ok, err = xpcall(function()
    typst.ui = nil
    typst.project = nil
    typst.navigation = nil
    typst.debug = nil

    vim.cmd("TypstInfo")
    vim.cmd("TypstStatus")
    vim.cmd("TypstFiles")
    vim.cmd("TypstLocks")
    vim.cmd("TypstCleanLocks")
    vim.cmd("TypstCheckInvariants")
    vim.cmd("TypstDoctor")
    vim.cmd("TypstTelemetry")
end, debug.traceback)

typst.debug = saved.debug
typst.ui = saved.ui
typst.project = saved.project
typst.navigation = saved.navigation

if not ok then
    error(err)
end

local compile_calls = {}
local force_clear_calls = {}
require("typst.ui.commands.compiler").register({
    api = {
        compiler = {
            compile = function(call_opts)
                compile_calls[#compile_calls + 1] = vim.deepcopy(call_opts)
            end,
            force_clear = function(call_opts)
                force_clear_calls[#force_clear_calls + 1] =
                    vim.deepcopy(call_opts)
            end,
        },
    },
})

local compile_ss_command = vim.api.nvim_get_commands({})["TypstCompileSS"]
assert(
    compile_ss_command
        and compile_ss_command.desc
        and compile_ss_command.desc:find("Alias for :TypstCompile", 1, true),
    "TypstCompileSS description should document alias semantics"
)

vim.cmd("TypstCompile")
vim.cmd("TypstCompileSS")
vim.cmd("TypstCompile! draft")
vim.cmd("TypstCompileSS! draft")
vim.cmd("TypstCompilerForceClear")
vim.cmd("TypstCompilerForceClear!")
vim.cmd("TypstCompilerForceClear retained-project-key")

assert(
    vim.deep_equal(compile_calls[1], compile_calls[2]),
    "TypstCompile and TypstCompileSS should pass identical default compile opts"
)
assert(
    vim.deep_equal(compile_calls[3], compile_calls[4]),
    "TypstCompile and TypstCompileSS should pass identical bang/profile compile opts"
)
assert(
    compile_calls[1].open == nil and compile_calls[1].profile == nil,
    "default compile commands should not force open/profile"
)
assert(
    compile_calls[3].open == true and compile_calls[3].profile == "draft",
    "bang/profile compile commands should pass open/profile"
)
assert(
    force_clear_calls[1] and force_clear_calls[1].force == false,
    "TypstCompilerForceClear should not force by default"
)
assert(
    force_clear_calls[2] and force_clear_calls[2].force == true,
    "TypstCompilerForceClear! should force discard"
)
assert(
    force_clear_calls[3]
        and force_clear_calls[3].force == false
        and force_clear_calls[3].key == "retained-project-key",
    "TypstCompilerForceClear should pass an optional project key"
)
assert(
    force_clear_calls[3].key_encoded == true,
    "TypstCompilerForceClear should mark command keys as encoded display keys"
)

local command_complete = require("typst.ui.commands.complete")
local compiler_service = require("typst.project.services.compiler")
local project_registry = require("typst.project.registry")

compiler_service.set(attached_project, { status = "stopping_failed" })
local retained_key = project_registry.encode_key(attached_project.key)
assert(
    vim.tbl_contains(command_complete.retained_project_key(""), retained_key),
    "force-clear completion should include retained/stopping_failed projects"
)
compiler_service.set(attached_project, { status = "idle" })
assert(
    vim.tbl_contains(command_complete.retained_project_key(""), retained_key),
    "force-clear completion should include non-retained projects for bang usage"
)

vim.cmd("qa!")
