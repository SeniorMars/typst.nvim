local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()

local uv = vim.uv or vim.loop
local fixture_dir = typst_test_cache_path("bibliography-diagnostics-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(fixture_dir, "p")

local main = fixture_dir .. "/main.typ"
local refs = fixture_dir .. "/refs.bib"

vim.fn.writefile({
    '#bibliography("refs.bib")',
    "#cite(<known>)",
    "#cite(<missing>)",
    "<collision>",
    "#cite(<collision>)",
}, main)

vim.fn.writefile({
    "@article{known,",
    "  title = {Known},",
    "}",
    "@article{duplicate,",
    "  title = {First},",
    "}",
    "@article{duplicate,",
    "  title = {Second},",
    "}",
    "@article{unused,",
    "  title = {Unused},",
    "}",
    "@article{collision,",
    "  title = {Collision},",
    "}",
}, refs)

typst.setup({
    root = fixture_dir,
    output_dir = typst_test_cache_path("bibliography-diagnostics-output"),
})
vim.cmd.edit(main)
vim.bo.filetype = "typst"
local project = assert(
    typst.project.attach(0),
    "bibliography diagnostics fixture should attach"
)

local result = typst.bibliography.diagnostics({
    project = project,
    quickfix = true,
    open = false,
})
assert(result.ok, "bibliography diagnostics should succeed")
assert(
    result.diagnostics >= 4,
    "bibliography diagnostics should report undefined, duplicate, unused, and collision cases"
)

local messages = {}
for _, diagnostics in pairs(result.by_buffer or {}) do
    for _, diagnostic in ipairs(diagnostics) do
        messages[diagnostic.message] = true
    end
end

assert(
    messages["Undefined citation `missing`"],
    "bibliography diagnostics should report explicit missing cites"
)
assert(
    messages["Duplicate bibliography key `duplicate`"],
    "bibliography diagnostics should report duplicate keys"
)
assert(
    messages["Unused bibliography entry `unused`"],
    "bibliography diagnostics should report unused entries"
)
assert(
    messages["Bibliography key `collision` also exists as a label"],
    "bibliography diagnostics should report label/citation collisions"
)

local qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(
    qf.title:find("typst.nvim bibliography", 1, true),
    "bibliography diagnostics should populate quickfix"
)
assert(
    #qf.items == result.diagnostics,
    "bibliography quickfix should include every bibliography diagnostic"
)
local qf_types = {}
for _, item in ipairs(qf.items) do
    qf_types[item.type] = true
end
assert(qf_types.E, "bibliography quickfix should mark errors as E")
assert(qf_types.W, "bibliography quickfix should keep warnings/hints as W")

local namespace =
    typst.bibliography.diagnostics_namespace({ project = project })
local published = 0
for bufnr in pairs(result.by_buffer or {}) do
    published = published
        + #vim.diagnostic.get(bufnr, { namespace = namespace })
end
assert(
    published == result.diagnostics,
    "bibliography diagnostics should publish to their own namespace"
)

local other_main = fixture_dir .. "/other.typ"
vim.fn.writefile({
    '#bibliography("refs.bib")',
    "#cite(<duplicate>)",
    "#cite(<unused>)",
}, other_main)
local other_project = {
    key = "bibliography-diagnostics-other",
    root = fixture_dir,
    main = other_main,
    bufs = {},
    files = {},
    dependencies = {},
}
local other_result = typst.bibliography.diagnostics({
    project = other_project,
    quickfix = false,
    open = false,
})
local other_messages = {}
for _, diagnostics in pairs(other_result.by_buffer or {}) do
    for _, diagnostic in ipairs(diagnostics) do
        other_messages[diagnostic.message] = true
    end
end
assert(
    not other_messages["Unused bibliography entry `unused`"],
    "shared bibliography diagnostics should be computed from each project's citations"
)
local other_namespace =
    typst.bibliography.diagnostics_namespace({ project = other_project })
assert(
    namespace ~= other_namespace,
    "bibliography diagnostics should use project-scoped namespaces"
)

local first_messages_after_other = {}
for bufnr in pairs(result.by_buffer or {}) do
    for _, diagnostic in
        ipairs(vim.diagnostic.get(bufnr, { namespace = namespace }))
    do
        first_messages_after_other[diagnostic.message] = true
    end
end
assert(
    first_messages_after_other["Unused bibliography entry `unused`"],
    "publishing another project should not replace existing bibliography diagnostics"
)

typst.bibliography.clear_diagnostics({ project = project })
local cleared = 0
for bufnr in pairs(result.by_buffer or {}) do
    cleared = cleared + #vim.diagnostic.get(bufnr, { namespace = namespace })
end
assert(cleared == 0, "bibliography diagnostics should clear their namespace")
local other_remaining = 0
for bufnr in pairs(other_result.by_buffer or {}) do
    other_remaining = other_remaining
        + #vim.diagnostic.get(bufnr, { namespace = other_namespace })
end
assert(
    other_remaining == other_result.diagnostics,
    "clearing one bibliography project should leave others intact"
)
typst.bibliography.clear_diagnostics({ project = other_project })
vim.cmd("TypstBibliographyDiagnostics")
local command_qf = vim.fn.getqflist({ title = 1, items = 1 })
assert(
    command_qf.title:find("typst.nvim bibliography", 1, true),
    "command should populate bibliography quickfix"
)

vim.cmd("qa!")
