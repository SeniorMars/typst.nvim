local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("bug-report-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local function report_text(report)
    return table.concat(report.lines or {}, "\n")
end

local result = typst.report({ open = false, echo = false })
assert(result.ok == true, "typst.report should generate a report")
assert(result.redacted == true, "bug reports should redact by default")
assert(type(result.data) == "table", "bug report should include data")
assert(
    result.data.schema == "typst.nvim.bug_report.v1",
    "bug report should include a stable schema name"
)
assert(result.data.api.api == 1, "bug report should include public API version")
assert(
    result.data.invariants and result.data.invariants.ok == true,
    "bug report should include invariant status"
)
assert(
    type(result.data.projects) == "table" and #result.data.projects >= 1,
    "bug report should include project snapshots"
)
assert(
    type(result.lines) == "table" and type(result.lines[1]) == "string",
    "bug report should include JSON lines"
)
assert(#result.lines > 1, "bug reports should be pretty-readable by default")
local decoded = vim.json.decode(report_text(result))
assert(
    decoded.schema == "typst.nvim.bug_report.v1",
    "bug report JSON should decode"
)
local compact = typst.report({ open = false, echo = false, pretty = false })
assert(
    compact.ok == true and #compact.lines == 1,
    "bug reports should support compact JSON output"
)
local capped = typst.report({
    open = false,
    echo = false,
    max_logs = 0,
    max_operations = 0,
    max_projects = 0,
    max_retained = 0,
    max_telemetry_entries = 1,
})
assert(capped.ok == true, "capped bug report should generate")
assert(#capped.data.projects == 0, "bug report project cap should apply")
assert(#capped.data.logs == 0, "bug report log cap should apply")
assert(
    capped.data.limits.max_projects == 0 and capped.data.limits.max_logs == 0,
    "bug report should record applied size caps"
)
assert(
    (capped.data.truncated.projects or 0) >= 1,
    "bug report should record truncated project count"
)

local home = vim.uv.os_homedir()
if type(home) == "string" and home ~= "" then
    assert(
        not report_text(result):find(home, 1, true),
        "redacted bug report should not include the home directory"
    )
    local ok, encoded_home = pcall(vim.uri_encode, home)
    if ok and type(encoded_home) == "string" and encoded_home ~= "" then
        assert(
            not report_text(result):find(encoded_home, 1, true),
            "redacted bug report should not include encoded home directory"
        )
    end
end
assert(
    not report_text(result):find(root, 1, true),
    "redacted bug report should not include the cwd"
)
local ok, encoded_root = pcall(vim.uri_encode, root)
if ok and type(encoded_root) == "string" and encoded_root ~= "" then
    assert(
        not report_text(result):find(encoded_root, 1, true),
        "redacted bug report should not include encoded cwd"
    )
end
assert(
    report_text(result):find("<cwd>", 1, true),
    "redacted bug report should replace the cwd with a stable token"
)

local unredacted = typst.report({ open = false, redact = false })
local saw_project_key = false
for _, item in ipairs(unredacted.data.projects or {}) do
    if item.key == project.key then
        saw_project_key = true
        break
    end
end
assert(saw_project_key, "unredacted bug report should include project keys")

local ui_result = typst.ui.bug_report({ open = false, echo = false })
assert(ui_result.ok == true, "ui.bug_report should generate a report")

local out = typst_test_cache_path("bug-report-output/report.json")
vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
local file_result = typst.report({ path = out, open = false })
assert(file_result.ok == true, "bug report should write to a file")
assert(vim.fn.filereadable(out) == 1, "bug report file should exist")
assert(
    vim.json.decode(table.concat(vim.fn.readfile(out), "\n")).schema
        == "typst.nvim.bug_report.v1",
    "written bug report should be JSON"
)

local write_fail_dir = typst_test_cache_path("bug-report-output/write-failure")
vim.fn.mkdir(write_fail_dir, "p")
local write_failure = typst.report({ path = write_fail_dir, open = false })
assert(
    write_failure.ok == false and write_failure.reason == "write_failed",
    "bug report write failures should be structured"
)

typst.reset({ force = true })
typst.setup({
    root = root,
    executable = { "printf", "typst 9.9.9" },
    output_dir = typst_test_cache_path("bug-report-output/prefix-output"),
})
local prefix_result = typst.report({ open = false, echo = false })
assert(prefix_result.ok == true, "bug report should work with executable lists")
assert(
    vim.deep_equal(prefix_result.data.environment.typst.command, {
        "printf",
        "typst 9.9.9",
        "--version",
    }),
    "bug report should flatten executable prefixes before probing Typst"
)

local out_with_spaces =
    typst_test_cache_path("bug-report-output/path with spaces/report file.json")
vim.fn.mkdir(vim.fn.fnamemodify(out_with_spaces, ":h"), "p")
local spaces_result = typst.report({ path = out_with_spaces, open = false })
assert(spaces_result.ok == true, "bug report should write paths with spaces")
assert(
    vim.fn.filereadable(out_with_spaces) == 1,
    "bug report path with spaces should exist"
)

local outside_root = typst_test_cache_path("bug-report-output/outside project")
vim.fn.mkdir(outside_root, "p")
local outside_main = outside_root .. "/main.typ"
vim.fn.writefile({ "= Outside" }, outside_main)
typst.reset({ force = true })
typst.setup({
    root = outside_root,
    output_dir = typst_test_cache_path("bug-report-output/outside-output"),
})
vim.cmd.edit(outside_main)
typst.project.set_main(outside_main)
local outside_report = typst.report({ open = false, echo = false })
assert(outside_report.ok == true, "outside-root bug report should generate")
assert(
    not report_text(outside_report):find(outside_root, 1, true),
    "bug report should redact project roots outside cwd"
)
assert(
    report_text(outside_report):find("<project:", 1, true),
    "bug report should replace project roots with stable tokens"
)

local original_encode = vim.json.encode
vim.json.encode = function()
    error("synthetic encode failure")
end
local ok_report, encode_failure = pcall(typst.report, { open = false })
vim.json.encode = original_encode
assert(ok_report, "bug report encode failure should not throw")
assert(
    encode_failure.ok == false and encode_failure.reason == "json_encode_failed",
    "bug report JSON encoding failures should be structured"
)

local open_result = typst.report({ open = true })
assert(
    type(open_result.buffer) == "number"
        and vim.api.nvim_buf_is_valid(open_result.buffer),
    "bug report should open a scratch buffer when requested"
)

vim.cmd("qa!")
