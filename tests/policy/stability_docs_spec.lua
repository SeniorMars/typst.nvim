local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function read(rel)
    return table.concat(vim.fn.readfile(root .. "/" .. rel), "\n")
end

local lifecycle = read("docs/architecture-lifecycle.md")
for _, text in ipairs({
    "Project State",
    "Compiler State",
    "Preview State",
    "Diagnostics State",
    "Cache Invalidation Map",
    "Async Callback Rule",
    "backend confirmed open",
    "Every confirmed stop releases output ownership",
    "A buffer belongs to at most one live project key",
}) do
    assert(
        lifecycle:find(text, 1, true),
        "architecture lifecycle docs should include: " .. text
    )
end

local policy = read("docs/stability-policy.md")
for _, text in ipairs({
    "No silent wrong project",
    "No orphaned user state",
    "No hidden destructive cleanup",
    "Compatibility Matrix",
    "API And Deprecation Policy",
    "Feature Freeze Rule",
}) do
    assert(
        policy:find(text, 1, true),
        "stability policy docs should include: " .. text
    )
end

local release_gates = read("docs/release-gates.md")
assert(
    release_gates:find("docs/architecture-lifecycle.md", 1, true)
        and release_gates:find("docs/stability-policy.md", 1, true),
    "release gates should link lifecycle and stability policy docs"
)

local checklist = read("docs/stable-core-checklist.md")
assert(
    checklist:find(":TypstBugReport", 1, true),
    "stable-core checklist should require bug-report artifacts"
)

vim.cmd("qa!")
