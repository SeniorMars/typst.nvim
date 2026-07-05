local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("count-output"),
})
local sample = {
    "= Main Heading",
    "Plain words here.",
    "#let hidden = 10",
    "More *strong words* and #emph[visible text].",
    "$ alpha + beta $",
    "// comment ignored",
}

local text_count = typst.ui.count({
    text = table.concat(sample, "\n"),
    echo = false,
})
assert(
    text_count.words == 11,
    ("text count should ignore Typst syntax, got %d"):format(text_count.words)
)
assert(
    text_count.characters > 0,
    "text count should include visible characters"
)
assert(
    text_count.characters_with_spaces >= text_count.characters,
    "character count with spaces should be larger"
)

local url_count = typst.ui.count({
    text = "Visit https://example.com/path now.",
    echo = false,
})
assert(
    url_count.visible_text:find("example", 1, true),
    "count fallback scanner should not treat URL slashes as a comment"
)

local count_fixture = root .. "/tests/fixtures/count/visible_text.typ"
local fixture_count = typst.ui.count({
    text = table.concat(vim.fn.readfile(count_fixture), "\n"),
    echo = false,
})
assert(
    fixture_count.words == 37,
    ("count fixture should document heuristic visible words, got %d"):format(
        fixture_count.words
    )
)
assert(
    fixture_count.visible_text:find("Function content remains visible", 1, true),
    "count fixture should keep visible function body text"
)
assert(
    fixture_count.visible_text:find("example", 1, true),
    "count fixture should keep URL prose"
)
for _, hidden in ipairs({
    "Hidden comment",
    "ignored words",
    "alpha",
    "hidden fenced raw",
    "ignored raw words",
    "sec:intro",
    "label:intro",
}) do
    assert(
        not fixture_count.visible_text:find(hidden, 1, true),
        "count fixture should hide " .. hidden
    )
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, sample)
vim.bo[buf].filetype = "typst"

local buffer_count = typst.ui.count({ bufnr = buf, echo = false })
assert(
    buffer_count.scope == "buffer",
    "buffer count should report buffer scope"
)
assert(
    buffer_count.words == 11,
    ("buffer count should match text count, got %d"):format(buffer_count.words)
)

local selection_count = typst.ui.count({
    bufnr = buf,
    line1 = 1,
    line2 = 2,
    range = true,
    echo = false,
})
assert(
    selection_count.scope == "selection",
    "range count should report selection scope"
)
assert(
    selection_count.words == 5,
    ("range count should count selected visible words, got %d"):format(
        selection_count.words
    )
)

local echoed = {}
local original_echo = vim.api.nvim_echo
rawset(vim.api, "nvim_echo", function(chunks)
    for _, chunk in ipairs(chunks) do
        echoed[#echoed + 1] = chunk[1]
    end
end)

vim.cmd("1,2TypstCount")
vim.api.nvim_echo = original_echo
assert(
    table.concat(echoed, "\n"):find("words=5"),
    "TypstCount range should echo selected word count"
)

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project =
    assert(typst.project.attach(0), "attach should return a project")

local project_count = typst.ui.count({ project = true, echo = false })
assert(
    project_count.scope == "project",
    "project count should report project scope"
)
assert(project_count.files >= 1, "project count should include project files")
assert(
    project_count.per_file[project.main],
    "project count should include the main file"
)
assert(
    project_count.words >= 1,
    "project count should include visible prose words"
)

local snapshot = typst.ui.status()
assert(
    snapshot.words == 1,
    ("status should expose current buffer word count, got %s"):format(
        snapshot.words
    )
)
assert(
    snapshot.characters > 0,
    "status should expose current buffer character count"
)
assert(
    typst.ui.statusline({ words = true }) == "Typst:idle main.typ 1w",
    "statusline should optionally include words"
)

vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "= Unsaved",
    "Unsaved project buffer words count here.",
})
local unsaved_project_count = typst.ui.count({ project = true, echo = false })
assert(
    unsaved_project_count.per_file[project.main].visible_text:find(
        "Unsaved project buffer words",
        1,
        true
    ),
    "project count should prefer unsaved loaded buffer contents"
)

echoed = {}
rawset(vim.api, "nvim_echo", function(chunks)
    for _, chunk in ipairs(chunks) do
        echoed[#echoed + 1] = chunk[1]
    end
end)

vim.cmd("TypstCount!")
vim.api.nvim_echo = original_echo
assert(
    table.concat(echoed, "\n"):find("%[project%]"),
    "TypstCount! should echo project count"
)

vim.cmd("qa!")
