local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/tests/fixtures/fzf-runtime")

local index = require("typst.index")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("picker-output"),
    picker = {
        provider = "ui_select",
    },
})
local main = root .. "/tests/fixtures/basic/index-main.typ"
vim.cmd.edit(main)
vim.bo.filetype = "typst"
assert(typst.project.attach(0), "picker fixture should attach")

local all_items =
    typst.picker.items({ kind = "all", toc_backend = "treesitter" })
local function has_item(kind, matcher)
    for _, item in ipairs(all_items) do
        if item.kind == kind and matcher(item) then
            return true
        end
    end
    return false
end

assert(
    has_item("heading", function(item)
        return item.name == "Intro"
    end),
    "picker items should include headings"
)
assert(
    has_item("label", function(item)
        return item.name == "sec:intro"
    end),
    "picker items should include labels"
)
assert(
    has_item("reference", function(item)
        return item.name == "@sec:intro"
    end),
    "picker items should include references"
)
assert(
    has_item("citation", function(item)
        return item.name == "doe2020"
    end),
    "picker items should include citations"
)
assert(
    has_item("import", function(item)
        return item.name == "@preview/cetz:0.3.4"
    end),
    "picker items should include package imports"
)
assert(
    has_item("file", function(item)
        return item.name == "image: diagram.svg"
    end),
    "picker items should include indexed file paths"
)
assert(
    has_item("todo", function(item)
        return item.name == "TODO: wire layered TOC"
    end),
    "picker items should include TODO comments"
)
assert(
    has_item("definition", function(item)
        return item.name == "local-card"
    end),
    "picker items should include local definitions"
)

local old_index_collect = index.collect
rawset(index, "collect", function()
    return {
        headings = {
            {
                title = "Non-Main Heading",
                level = 1,
                source = {
                    path = "A:\\Users\\Charlie\\Project\\chapter.typ",
                    lnum = 1,
                    col = 1,
                },
            },
            {
                title = "Windows Main Heading",
                level = 1,
                source = {
                    path = "c:\\users\\charlie\\project\\main.typ",
                    lnum = 2,
                    col = 1,
                },
            },
        },
    }
end)
local windows_picker_items = typst.picker.items({
    project = {
        root = "C:/Users/Charlie/Project",
        main = "C:/Users/Charlie/Project/main.typ",
    },
    kind = "headings",
    toc_backend = "treesitter",
})
index.collect = old_index_collect
assert(
    windows_picker_items[1]
        and windows_picker_items[1].name == "Windows Main Heading",
    "picker sorting should treat Windows-equivalent paths as the project main"
)

local label_items = typst.picker.items({ kind = "labels", query = "intro" })
assert(#label_items == 1, "picker query should filter items")
assert(
    label_items[1].label:find("[label] sec:intro", 1, true),
    "picker label should be display-ready"
)
assert(
    label_items[1].source.path == main,
    "picker item should expose source path"
)

local bibliography_items =
    typst.picker.items({ kind = "bibliography", query = "doe2020" })
assert(
    #bibliography_items == 1,
    "bibliography picker kind should expose dedicated bibliography entries"
)
assert(
    bibliography_items[1].kind == "bibliography",
    "bibliography picker items should use bibliography kind"
)
assert(
    bibliography_items[1].citation_key == "doe2020",
    "bibliography picker should expose citation_key"
)
assert(
    bibliography_items[1].insert_text == "@doe2020",
    "bibliography picker should default to shorthand insertion"
)
local bibliography_function_items = typst.picker.items({
    kind = "bibliography",
    query = "doe2020",
    citation_form = "function",
})
assert(
    bibliography_function_items[1].insert_text == "#cite(<doe2020>)",
    "bibliography picker should expose explicit cite insertion"
)
local bibliography_label_items = typst.picker.items({
    kind = "bibliography",
    query = "doe2020",
    citation_form = "label",
})
assert(
    bibliography_label_items[1].insert_text == "<doe2020>",
    "bibliography picker should expose raw key insertion"
)

local old_select = vim.ui.select
local selected_prompt = nil
local formatted = nil
rawset(vim.ui, "select", function(items, opts, on_choice)
    selected_prompt = opts.prompt
    formatted = opts.format_item(items[1])
    on_choice(items[1])
end)
vim.api.nvim_win_set_cursor(0, { 8, 0 })
local result = typst.picker.open({
    kind = "labels",
    backend = "ui_select",
    prompt = "Pick label",
})
vim.ui.select = old_select

assert(
    result.ok and result.backend == "ui_select",
    "ui_select picker should report the selected backend"
)
assert(
    selected_prompt == "Pick label",
    "ui_select picker should pass prompt through"
)
assert(
    assert(formatted):find("[label] sec:intro", 1, true),
    "ui_select picker should format items"
)
assert(
    vim.api.nvim_win_get_cursor(0)[1] == 1,
    "default picker action should jump to item source"
)

local custom_seen = nil
local custom = typst.picker.open({
    kind = "citations",
    backend = "custom",
    custom = function(items)
        custom_seen = items
        return { ok = true, backend = "test" }
    end,
})
assert(
    custom.ok and custom.backend == "test",
    "custom picker should return provider result"
)
local custom_seen_has_doe = false
for _, item in ipairs(custom_seen or {}) do
    custom_seen_has_doe = custom_seen_has_doe or item.name == "doe2020"
end
assert(
    custom_seen and custom_seen_has_doe,
    "custom picker should receive normalized items"
)

vim.g.typst_nvim_fzf_vim_spec = nil
local fzf_vim = typst.picker.open({
    kind = "labels",
    backend = "fzf_vim",
    prompt = "Pick with fzf.vim",
})
assert(
    fzf_vim.ok and fzf_vim.backend == "fzf_vim",
    "fzf.vim picker should report its backend"
)
assert(vim.g.typst_nvim_fzf_vim_spec, "fzf.vim picker should call fzf#run")
assert(
    vim.g.typst_nvim_fzf_vim_spec.source[1]:find("[label] sec:intro", 1, true),
    "fzf.vim picker should pass display-ready entries"
)

vim.cmd("qa!")
