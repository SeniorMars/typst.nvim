local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local path_util = require("typst.core.path")
local output_path = require("typst.compiler.output_path")

local project_root = typst_test_cache_path("output-path-validation")
vim.fn.delete(project_root, "rf")
vim.fn.mkdir(project_root, "p")

local project = {
    key = "output-path-validation",
    root = project_root,
    main = project_root .. "/main.typ",
}
vim.fn.writefile({ "= Main" }, project.main)

local function rejects(name, message)
    local ok, err = pcall(output_path.output_path, project, {
        output_format = "pdf",
        output_name = name,
        output_dir = project_root,
        allow_external_output = false,
    })
    assert(not ok, message .. " should reject")
    assert(tostring(err):find("output_name", 1, true), message .. " error")
end

rejects(".", "dot output_name")
rejects("..", "dot-dot output_name")
rejects("nested/paper", "separator output_name")
rejects("paper\0name", "NUL output_name")
rejects("paper\nname", "control-character output_name")

local format_ok, format_err = pcall(output_path.output_path, project, {
    output_format = "../pdf",
    output_name = "paper",
    output_dir = project_root,
    allow_external_output = true,
})
assert(not format_ok, "path-like output_format should reject")
assert(
    tostring(format_err):find("output_name", 1, true),
    "path-like output_format error"
)

local safe_output, safe_error = output_path.safe_output_path(project, {
    output_format = "../pdf",
    output_name = "paper",
    output_dir = project_root,
    allow_external_output = true,
}, {
    operation = "render",
})
assert(safe_output == nil, "safe helper should not return invalid path")
assert(safe_error and safe_error.ok == false, "safe helper should fail")
assert(
    safe_error.reason == "output_path_invalid",
    "safe helper should classify invalid output format"
)

local original_is_windows = path_util.is_windows
rawset(path_util, "is_windows", function()
    return true
end)
rejects("paper:name", "Windows reserved character output_name")
rejects("paper*name", "Windows wildcard output_name")
rejects("paper.", "Windows trailing dot output_name")
rejects("paper ", "Windows trailing space output_name")
rejects("CON", "Windows reserved device output_name")
rejects("NUL.pdf", "Windows reserved device with extension output_name")
rejects("COM1", "Windows COM device output_name")
rejects("LPT9.pdf", "Windows LPT device output_name")
path_util.is_windows = original_is_windows

local resolved = output_path.output_path(project, {
    output_format = "pdf",
    output_name = "paper",
    output_dir = project_root,
    allow_external_output = false,
})
assert(
    resolved:match("paper%.pdf$"),
    "basename output_name should receive output extension"
)
assert(
    path_util.path_within(resolved, project_root),
    "resolved output should stay inside output_dir"
)

vim.cmd("qa!")
