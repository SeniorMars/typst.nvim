local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local bibliography_diagnostics = require("typst.bibliography.diagnostics")
local diagnostics = require("typst.diagnostics")
local fonts = require("typst.metadata.fonts")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("diagnostics-namespace-output"),
    diagnostics = {
        enabled = true,
        use_quickfix = false,
    },
})

local fixture_dir =
    typst_test_cache_path(("diagnostics-namespace-%d"):format(vim.uv.hrtime()))
vim.fn.mkdir(fixture_dir, "p")
local shared = fixture_dir .. "/shared.typ"
vim.fn.writefile({ "= Shared" }, shared)
vim.cmd.edit(shared)
local bufnr = vim.api.nvim_get_current_buf()

local project_a = {
    key = "diagnostics-namespace-a",
    root = fixture_dir,
    main = fixture_dir .. "/a.typ",
    diagnostic_buffers = {},
}
local project_b = {
    key = "diagnostics-namespace-b",
    root = fixture_dir,
    main = fixture_dir .. "/b.typ",
    diagnostic_buffers = {},
}

diagnostics.publish(project_a, "shared.typ:1:1: error: project a")
diagnostics.publish(project_b, "shared.typ:1:1: error: project b")
diagnostics.publish(
    project_a,
    "shared.typ:1:1: warning: lint project a",
    { source = "lint" }
)
diagnostics.publish(
    project_a,
    "shared.typ:1:1: warning: grammar project a",
    { source = "typst grammar" }
)

local namespace_a = diagnostics.namespace_for(project_a)
local namespace_b = diagnostics.namespace_for(project_b)
local namespace_a_lint = diagnostics.namespace_for(project_a, "lint")
local namespace_a_grammar =
    diagnostics.namespace_for(project_a, "typst grammar")
local namespace_a_bibliography =
    bibliography_diagnostics.namespace_for(project_a)
local namespace_b_bibliography =
    bibliography_diagnostics.namespace_for(project_b)
local a_diagnostics = vim.diagnostic.get(bufnr, { namespace = namespace_a })
local b_diagnostics = vim.diagnostic.get(bufnr, { namespace = namespace_b })
local a_lint_diagnostics =
    vim.diagnostic.get(bufnr, { namespace = namespace_a_lint })
local a_grammar_diagnostics =
    vim.diagnostic.get(bufnr, { namespace = namespace_a_grammar })

assert(
    #a_diagnostics == 1,
    "project A should publish diagnostics in its own namespace"
)
assert(
    #b_diagnostics == 1,
    "project B should publish diagnostics in its own namespace"
)
assert(
    a_diagnostics[1].message == "project a",
    "project A diagnostic should be retained"
)
assert(
    b_diagnostics[1].message == "project b",
    "project B diagnostic should be retained"
)
assert(
    #a_lint_diagnostics == 1
        and a_lint_diagnostics[1].message == "lint project a",
    "project A lint diagnostic should be retained separately"
)
assert(
    #a_grammar_diagnostics == 1
        and a_grammar_diagnostics[1].message == "grammar project a",
    "project A grammar diagnostic should be retained separately"
)

local seen_namespaces = {}
for _, source in ipairs({
    "compiler",
    "lint",
    "typst grammar",
    "bibliography",
    "typst fonts",
    "custom source!",
}) do
    local ns_a = diagnostics.namespace_for(project_a, source)
    local ns_b = diagnostics.namespace_for(project_b, source)
    assert(
        ns_a ~= ns_b,
        ("diagnostic source %s should be project-scoped"):format(source)
    )
    assert(
        not seen_namespaces[ns_a],
        ("diagnostic source %s should have its own namespace"):format(source)
    )
    seen_namespaces[ns_a] = source
end

assert(
    namespace_a_bibliography ~= namespace_b_bibliography,
    "bibliography diagnostics should use project-scoped namespaces"
)
assert(
    namespace_a_bibliography ~= namespace_a
        and namespace_a_bibliography ~= namespace_a_lint
        and namespace_a_bibliography ~= namespace_a_grammar,
    "bibliography diagnostics should not collide with compiler/lint/grammar namespaces"
)
assert(
    fonts.namespace ~= namespace_a
        and fonts.namespace ~= namespace_a_lint
        and fonts.namespace ~= namespace_a_grammar
        and fonts.namespace ~= namespace_a_bibliography,
    "font diagnostics should have a dedicated namespace"
)

diagnostics.clear(project_a, { source = "lint" })
assert(
    #vim.diagnostic.get(bufnr, { namespace = namespace_a_lint }) == 0,
    "clearing project A lint should clear only lint diagnostics"
)
assert(
    #vim.diagnostic.get(bufnr, { namespace = namespace_a }) == 1,
    "clearing project A lint should not clear compiler diagnostics"
)
assert(
    #vim.diagnostic.get(bufnr, { namespace = namespace_a_grammar }) == 1,
    "clearing project A lint should not clear grammar diagnostics"
)

diagnostics.clear_buffer(project_a, bufnr)
assert(
    #vim.diagnostic.get(bufnr, { namespace = namespace_a }) == 0,
    "clearing one project buffer should reset compiler diagnostics"
)
assert(
    #vim.diagnostic.get(bufnr, { namespace = namespace_a_grammar }) == 0,
    "clearing one project buffer should reset grammar diagnostics"
)
assert(
    #vim.diagnostic.get(bufnr, { namespace = namespace_b }) == 1,
    "clearing one project buffer should not clear another project namespace"
)

diagnostics.clear(project_a)
assert(
    #vim.diagnostic.get(bufnr, { namespace = namespace_a }) == 0,
    "clearing project A should clear project A"
)
assert(
    #vim.diagnostic.get(bufnr, { namespace = namespace_b }) == 1,
    "clearing project A should not clear project B diagnostics"
)

local allowed_diagnostic_writers = {
    ["lua/typst/diagnostics/init.lua"] = true,
    ["lua/typst/bibliography/diagnostics.lua"] = true,
    ["lua/typst/metadata/fonts.lua"] = true,
}
local stray_writers = {}
for _, file in
    ipairs(vim.fn.globpath(root .. "/lua/typst", "**/*.lua", false, true))
do
    local rel = file:sub(#root + 2)
    for lnum, line in ipairs(vim.fn.readfile(file)) do
        if
            line:find("vim.diagnostic.set", 1, true)
            or line:find("vim.diagnostic.reset", 1, true)
        then
            if not allowed_diagnostic_writers[rel] then
                stray_writers[#stray_writers + 1] = ("%s:%d:%s"):format(
                    rel,
                    lnum,
                    vim.trim(line)
                )
            end
        end
    end
end
assert(
    #stray_writers == 0,
    "diagnostic publication should stay behind source/project namespace modules:\n"
        .. table.concat(stray_writers, "\n")
)

vim.cmd("qa!")
