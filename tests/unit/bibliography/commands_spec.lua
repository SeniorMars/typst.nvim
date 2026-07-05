local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local path_util = require("typst.core.path")
local typst = require("typst")

typst.reset()

local uv = vim.uv or vim.loop
local fixture_dir = typst_test_root_path("bibliography-commands-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(fixture_dir .. "/attachments", "p")

local main = fixture_dir .. "/main.typ"
local refs = fixture_dir .. "/refs.bib"
local attachment = fixture_dir .. "/attachments/doe2026.pdf"
local picker_calls = {}

vim.fn.writefile({
    '#bibliography("refs.bib")',
    "See @doe2026.",
    "",
    "#let citation = ",
    "#cite(",
}, main)

vim.fn.writefile({
    "@article{doe2026,",
    "  author = {Doe, Jane and Roe, Richard},",
    "  title = {A Typst Citation Suite},",
    "  year = {2026},",
    "  journal = {Journal of Project Editing},",
    "  keywords = {typst, citation, picker},",
    "  abstract = {Searchable abstract phrase for command coverage.},",
    "}",
    "@xdata{sharedmeta,",
    "  journal = {Inherited Journal of References},",
    "}",
    "@inproceedings{smith2024,",
    "  author = {Smith, Sam},",
    "  title = {Picker Integration},",
    "  booktitle = {Proceedings of Neovim Tools},",
    "  xdata = {sharedmeta},",
    "  year = {2024},",
    "}",
}, refs)
vim.fn.writefile({ "%PDF-1.7" }, attachment)

typst.setup({
    root = fixture_dir,
    output_dir = typst_test_cache_path("bibliography-commands-output"),
    bibliography = {
        attachment_fields = { "pdf", "file", "attachment" },
        attachment_paths = { "attachments/{key}.pdf" },
    },
    picker = {
        provider = "custom",
        custom = function(items, opts)
            picker_calls[#picker_calls + 1] = {
                items = items,
                opts = opts,
            }
            return {
                ok = true,
                backend = "test",
                items = items,
            }
        end,
    },
})
vim.cmd.edit(main)
vim.bo.filetype = "typst"
local project =
    assert(typst.project.attach(0), "bibliography command fixture attaches")

local function one_search(query, expected)
    local results = typst.bibliography.search({
        project = project,
        query = query,
    })
    assert(
        #results == 1 and results[1].key == expected,
        ("bibliography search for %q should find %s"):format(query, expected)
    )
    return results[1]
end

local function search_includes(query, expected)
    local results = typst.bibliography.search({
        project = project,
        query = query,
    })
    for _, item in ipairs(results) do
        if item.key == expected then
            return item
        end
    end
    error(
        ("bibliography search for %q should include %s"):format(query, expected)
    )
end

one_search("doe2026", "doe2026")
one_search("Jane", "doe2026")
one_search("Typst Citation Suite", "doe2026")
one_search("2026", "doe2026")
one_search("Journal of Project Editing", "doe2026")
one_search("typst, citation, picker", "doe2026")
one_search("Searchable abstract phrase", "doe2026")
one_search("Proceedings of Neovim Tools", "smith2024")
search_includes("Inherited Journal of References", "smith2024")

local picker_items = typst.picker.items({
    project = project,
    kind = "bibliography",
    query = "Searchable abstract phrase",
})
assert(
    #picker_items == 1 and picker_items[1].citation_key == "doe2026",
    "bibliography picker query should search citation metadata"
)

local inherited_picker_items = typst.picker.items({
    project = project,
    kind = "bibliography",
    query = "Inherited Journal of References",
})
assert(
    vim.tbl_contains(
        vim.tbl_map(function(item)
            return item.citation_key
        end, inherited_picker_items),
        "smith2024"
    ),
    "bibliography picker query should search expanded citation metadata"
)

local preview = typst.bibliography.preview({
    project = project,
    key = "doe2026",
})
assert(
    preview.ok and preview.text:find("A Typst Citation Suite", 1, true),
    "citation preview should resolve a key through the project bibliography"
)

local target = typst.bibliography.open({
    project = project,
    key = "doe2026",
    open = false,
})
assert(
    target.ok and path_util.same_path(target.target.path, refs),
    "citation open should resolve bibliography entry targets by key"
)

vim.api.nvim_win_set_cursor(0, { 2, #"See @" })
local missing_target = typst.bibliography.open({
    project = project,
    key = "missing-key",
    open = false,
})
assert(
    not missing_target.ok,
    "explicit missing citation keys should not fall back to the cursor target"
)

local found_attachment = typst.bibliography.attachment({
    project = project,
    key = "doe2026",
})
assert(
    found_attachment.ok
        and path_util.same_path(found_attachment.path, attachment),
    "citation attachment lookup should resolve a key through the project bibliography"
)

local attachments = typst.bibliography.attachments({
    project = project,
    query = "Jane",
})
assert(
    attachments.ok
        and attachments.count == 1
        and path_util.same_path(attachments.attachments[1].path, attachment),
    "bibliography attachments should aggregate search matches"
)

vim.api.nvim_win_set_cursor(0, { 2, #"See " })
assert(
    typst.bibliography.insert_text("doe2026", { project = project })
        == "@doe2026",
    "markup citation insert text should use shorthand syntax"
)

vim.api.nvim_win_set_cursor(0, { 4, #"#let citation = " })
assert(
    typst.bibliography.insert_text("doe2026", { project = project })
        == "#cite(<doe2026>)",
    "code citation insert text should use cite() syntax"
)

vim.api.nvim_win_set_cursor(0, { 5, #"#cite(" })
assert(
    typst.bibliography.insert_text("doe2026", { project = project })
        == "<doe2026>",
    "citation argument insert text should use raw label syntax"
)

vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.cmd("TypstCitationInsert doe2026")
local inserted = vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]
assert(inserted == "@doe2026", ":TypstCitationInsert should insert direct keys")

local single_main = fixture_dir .. "/single.typ"
local single_refs = fixture_dir .. "/single.bib"
vim.fn.writefile({
    '#bibliography("single.bib")',
    "",
}, single_main)
vim.fn.writefile({
    "@article{singlekey,",
    "  title = {Single Citation},",
    "}",
}, single_refs)
vim.cmd.edit(single_main)
vim.bo.filetype = "typst"
typst.project.attach(0)

local before_picker_calls = #picker_calls
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd("TypstCitationInsert")
local after_no_arg = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
assert(
    after_no_arg == "",
    ":TypstCitationInsert without a key should open the picker, not insert the only project citation"
)
assert(
    #picker_calls == before_picker_calls + 1
        and picker_calls[#picker_calls].opts.kind == "bibliography",
    ":TypstCitationInsert without a key should open the bibliography picker"
)

vim.cmd("qa!")
