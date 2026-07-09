local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local scanner = require("typst.project.scanner")

local fixture_root = typst_test_cache_path("scanner-static-contract")
vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root, "p")
local main = fixture_root .. "/main.typ"
vim.fn.writefile({
    "= Static scanner contract <café>",
    "The explicit reference works: #ref(<café>).",
    "The shorthand non-ASCII reference is intentionally skipped: @café.",
}, main)

local project = {
    root = fixture_root,
    main = main,
    bufs = {},
}

local record = scanner.scan_file_record(project, main)
local saw_label = false
local saw_explicit_reference = false
local saw_truncated_shorthand = false
local saw_non_ascii_shorthand = false

for _, label in ipairs(record.data.labels or {}) do
    saw_label = saw_label or label.name == "café"
end

for _, reference in ipairs(record.data.references or {}) do
    if reference.reference_style == "function" and reference.name == "café" then
        saw_explicit_reference = true
    end
    if reference.reference_style == "shorthand" and reference.name == "caf" then
        saw_truncated_shorthand = true
    end
    if reference.reference_style == "shorthand" and reference.name == "café" then
        saw_non_ascii_shorthand = true
    end
end

assert(saw_label == true, "static scanner should keep non-ASCII labels")
assert(
    saw_explicit_reference == true,
    "static scanner should keep explicit non-ASCII ref calls"
)
assert(
    saw_truncated_shorthand == false,
    "static scanner should not index truncated non-ASCII shorthand refs"
)
assert(
    saw_non_ascii_shorthand == false,
    "static scanner documents non-ASCII shorthand refs as outside its scope"
)

vim.cmd("qa!")
