local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()

local uv = vim.uv or vim.loop
local fixture_dir = typst_test_cache_path("bibliography-workflow-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(fixture_dir .. "/attachments", "p")

local main = fixture_dir .. "/main.typ"
local refs = fixture_dir .. "/refs.bib"
local other_refs = fixture_dir .. "/other-refs.bib"
local attachment = fixture_dir .. "/attachments/child.pdf"

vim.fn.writefile({
    '#bibliography("refs.bib")',
    '#bibliography("other-refs.bib")',
    "= Parent Label <parent>",
    "Custom myref(<local-label>) should keep the label definition.",
    "See @child and #cite(<parent>, <child>).",
    '#cite(<parent>, supplement: "<not-a-cite>").',
}, main)

vim.fn.writefile({
    "@proceedings{parent,",
    "  title = {Conference Parent},",
    "  publisher = {Parent Publisher},",
    "  year = {2026},",
    "}",
    "@xdata{shared,",
    "  journal = {Shared Journal},",
    "}",
    "@article{child,",
    "  author = {Doe, Jane},",
    "  title = {Child Paper},",
    "  crossref = {parent},",
    "  xdata = {shared},",
    "}",
}, refs)
vim.fn.writefile({
    "@article{external,",
    "  title = {External Collision},",
    "  author = {Other, Erin},",
    "  year = {2025},",
    "}",
    "@article{other,",
    "  title = {Other Paper},",
    "  author = {Other, Oscar},",
    "  year = {2024},",
    "}",
}, other_refs)
vim.fn.writefile({ "%PDF-1.7" }, attachment)

typst.setup({
    root = fixture_dir,
    output_dir = typst_test_cache_path("bibliography-workflow-output"),
    bibliography = {
        attachment_fields = { "pdf", "file", "attachment" },
        attachment_paths = { "attachments/{key}.pdf" },
    },
})
vim.cmd.edit(main)
vim.bo.filetype = "typst"
local project = assert(typst.project.attach(0), "bibliography fixture attaches")

local collected = typst.index.collect({ project = project })
local has_local_label = false
local parent_cite_is_citation = false
local has_not_a_cite_reference = false
for _, label in ipairs(collected.labels or {}) do
    has_local_label = has_local_label or label.name == "local-label"
end
for _, reference in ipairs(collected.references or {}) do
    if reference.name == "parent" and reference.reference_style == "cite" then
        parent_cite_is_citation = parent_cite_is_citation
            or reference.reference_target == "citation"
    end
    has_not_a_cite_reference = has_not_a_cite_reference
        or reference.name == "not-a-cite"
end
assert(
    has_local_label,
    "scanner should not hide labels inside unrelated myref() calls"
)
assert(
    parent_cite_is_citation,
    "explicit cite references should prefer citation targets over same-named labels"
)
assert(
    not has_not_a_cite_reference,
    "scanner should ignore angle brackets inside cite string/options"
)

local fields = typst.bibliography.expanded_fields({
    path = refs,
    key = "child",
})
assert(fields.title == "Child Paper", "expanded fields should keep own title")
assert(fields.year == "2026", "expanded fields should inherit crossref year")
assert(
    fields.publisher == "Parent Publisher",
    "expanded fields should inherit crossref fields"
)
assert(
    fields.journal == "Shared Journal",
    "expanded fields should inherit xdata fields"
)

local preview = typst.bibliography.preview({
    path = refs,
    key = "child",
})
assert(preview.ok, "bibliography preview should produce text")
assert(
    preview.text:find("Doe, Jane", 1, true)
        and preview.text:find("2026", 1, true)
        and preview.text:find("Child Paper", 1, true),
    "bibliography preview should include author, year, and title"
)

local found_attachment = typst.bibliography.attachment({
    path = refs,
    key = "child",
})
assert(found_attachment.ok, "bibliography attachment should be discovered")
assert(
    found_attachment.path == attachment,
    "bibliography attachment should use configured path patterns"
)

local status = typst.bibliography.status({ project = project })
assert(status.ok, "bibliography status should succeed")
assert(status.paths == 2, "bibliography status should count paths")
assert(status.entries == 5, "bibliography status should count entries")
assert(status.used == 2, "bibliography status should count used citations")
assert(
    status.missing_count == 0,
    "bibliography status should report no missing"
)
assert(status.unused == 3, "bibliography status should count unused entries")

vim.api.nvim_buf_set_lines(0, 3, 3, false, {
    "Repeated missing #cite(<ghost>, <ghost>) and @ghost.",
})
typst.index.reset(project)
local missing_status = typst.bibliography.status({ project = project })
assert(
    missing_status.missing_count == 1,
    "bibliography status should count unique missing citation keys"
)

local original_buf = vim.api.nvim_get_current_buf()
local cite_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, cite_buf)
vim.api.nvim_buf_set_lines(cite_buf, 0, -1, false, { "#cite()" })
vim.api.nvim_win_set_cursor(0, { 1, 6 })
assert(
    typst.bibliography.insert_text("child", { bufnr = cite_buf, winid = 0 })
        == "<child>",
    "bibliography insertion before cite closing paren should stay inside cite args"
)
vim.cmd("vsplit")
local stale_winid = vim.api.nvim_get_current_win()
vim.cmd("close")
vim.api.nvim_win_set_cursor(0, { 1, 6 })
local stale_ok, stale_insert = pcall(typst.bibliography.insert_text, "child", {
    bufnr = cite_buf,
    winid = stale_winid,
})
assert(stale_ok, "bibliography insertion should tolerate a stale winid")
assert(
    stale_insert == "<child>",
    "stale bibliography winid should fall back to the current matching window"
)
vim.api.nvim_win_set_buf(0, original_buf)
vim.api.nvim_buf_delete(cite_buf, { force = true })
local fallback_refs = fixture_dir .. "/fallback-source.bib"
local unrelated_refs = fixture_dir .. "/fallback-unrelated.bib"
vim.fn.writefile({
    "@article{fallback-child,",
    "  title = {Fallback Child},",
    "}",
    "@article{fallback-unused,",
    "  title = {Fallback Unused},",
    "}",
}, fallback_refs)
vim.fn.writefile({
    "@article{unrelated-key,",
    "  title = {Should Not Be Scanned},",
    "}",
}, unrelated_refs)

local index = require("typst.index")
local original_collect = index.collect
local fallback_ok, fallback_err = xpcall(function()
    rawset(index, "collect", function()
        return {
            bibliography_paths = {},
            citations = {
                {
                    name = "fallback-child",
                    source = { path = fallback_refs, lnum = 1, col = 10 },
                },
                {
                    name = "fallback-unused",
                    source = { path = fallback_refs, lnum = 4, col = 10 },
                },
            },
            references = {
                {
                    name = "fallback-child",
                    reference_target = "citation",
                    source = { path = main, lnum = 5, col = 5 },
                },
            },
        }
    end)
    local fallback_status = typst.bibliography.status({ project = project })
    assert(fallback_status.ok, "fallback bibliography status should succeed")
    assert(
        fallback_status.paths == 1,
        "fallback bibliography status should use only citation source files"
    )
    assert(
        fallback_status.entries == 2,
        "fallback bibliography status should parse entries from citation source"
    )
    assert(
        fallback_status.used == 1 and fallback_status.unused == 1,
        "fallback bibliography status should still compare used and unused keys"
    )
    assert(
        fallback_status.missing_count == 0,
        "fallback bibliography status should not invent missing keys"
    )

    local fallback_plan = typst.bibliography.rename_plan({
        project = project,
        old_key = "fallback-child",
        new_key = "unrelated-key",
    })
    assert(
        fallback_plan.path == fallback_refs,
        "fallback rename should resolve the entry path from citation sources"
    )
    assert(
        fallback_plan.duplicate == false,
        "fallback rename should not scan unrelated bibliography files"
    )
    assert(
        #fallback_plan.edits == 2,
        "fallback rename should edit the bibliography entry and Typst reference"
    )
end, debug.traceback)
index.collect = original_collect
if not fallback_ok then
    error(fallback_err)
end

local plan = typst.bibliography.rename_plan({
    project = project,
    path = refs,
    old_key = "child",
    new_key = "renamed-child",
})
assert(
    #plan.edits == 3,
    "bibliography rename plan should update entry, shorthand cite, and later cite() key"
)

local cross_file_duplicate = typst.bibliography.rename_key({
    project = project,
    path = refs,
    old_key = "child",
    new_key = "external",
})
assert(
    cross_file_duplicate
        and not cross_file_duplicate.ok
        and cross_file_duplicate.reason == "duplicate_key",
    "bibliography rename should reject duplicate keys across bibliography files"
)

local renamed = typst.bibliography.rename_key({
    project = project,
    path = refs,
    old_key = "child",
    new_key = "renamed-child",
})
assert(renamed.ok, "bibliography rename should apply")
assert(#renamed.files == 2, "bibliography rename should edit refs and source")

local main_bufnr =
    assert(vim.fn.bufnr(main), "renamed source buffer should still be loaded")
local main_lines =
    table.concat(vim.api.nvim_buf_get_lines(main_bufnr, 0, -1, false), "\n")
local ref_lines = table.concat(vim.fn.readfile(refs), "\n")
assert(
    main_lines:find("@renamed-child", 1, true)
        and main_lines:find("#cite(<parent>, <renamed-child>)", 1, true),
    "bibliography rename should update shorthand and later explicit citations"
)
assert(
    ref_lines:find("@article{renamed-child,", 1, true),
    "bibliography rename should update the BibTeX key"
)

local duplicate = typst.bibliography.rename_key({
    project = project,
    path = refs,
    old_key = "renamed-child",
    new_key = "parent",
})
assert(
    duplicate and not duplicate.ok and duplicate.reason == "duplicate_key",
    "bibliography rename should reject duplicate keys by default"
)

vim.cmd("qa!")
