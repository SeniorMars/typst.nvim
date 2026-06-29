local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local conceal = require("typst.conceal")
local perf = require("tests.performance_report")
local toc = require("typst.edit.toc")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("performance-output"),
    completion = {
        universe_index_paths = { root .. "/tests/fixtures/universe-index.json" },
        font_scan_timeout_ms = 0,
    },
})

local old_package_cache_path = vim.env.TYPST_PACKAGE_CACHE_PATH
vim.env.TYPST_PACKAGE_CACHE_PATH = root .. "/tests/fixtures/packages"

local spec_name = "performance_spec"
local scale = perf.scale()
local budgets = {
    project_index_collect = 2000 * scale,
    project_index_cached = 500 * scale,
    toc_collect = 2000 * scale,
    conceal_matches = 1500 * scale,
    completion = 1500 * scale,
}

local function assert_budget(name, budget_ms, fn)
    return perf.assert_budget(spec_name, name, budget_ms, fn)
end

local function has_item(items, predicate)
    for _, item in ipairs(items or {}) do
        if predicate(item) then
            return true
        end
    end
    return false
end

local function has_compatible_typst_conceal_query(bufnr)
    local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "typst")
    if not ok_parser or not parser then
        return false
    end

    local ok_query, query = pcall(vim.treesitter.query.get, "typst", "conceal")
    return ok_query and query ~= nil
end

local main = root .. "/tests/fixtures/basic/index-main.typ"
vim.cmd.edit(main)
local project =
    assert(typst.project.attach(0), "performance fixture should attach")

typst.index.reset(project)
local collected = assert_budget(
    "project index collect",
    budgets.project_index_collect,
    function()
        return typst.index.collect({ project = project })
    end
)
assert(
    has_item(collected.labels, function(item)
        return item.name == "sec:intro"
    end),
    "project index performance fixture should include labels"
)

local cached = assert_budget(
    "project index cached collect",
    budgets.project_index_cached,
    function()
        return typst.index.collect({ project = project })
    end
)
assert(
    has_item(cached.definitions, function(item)
        return item.name == "local-card"
    end),
    "cached project index collection should preserve definitions"
)

local toc_items = assert_budget("TOC collect", budgets.toc_collect, function()
    return toc.collect(project, { backend = "treesitter" })
end)
assert(
    has_item(toc_items, function(item)
        return (item.layer == nil or item.layer == "heading")
            and item.title == "Intro"
    end),
    "TOC performance fixture should include headings"
)

local conceal_fixture = root .. "/tests/fixtures/basic/conceal.typ"
vim.cmd.edit(conceal_fixture)
vim.bo.filetype = "typst"
if has_compatible_typst_conceal_query(0) then
    local conceal_items = assert_budget(
        "conceal matches",
        budgets.conceal_matches,
        function()
            return conceal.matches(0)
        end
    )
    assert(
        #conceal_items > 0,
        "conceal performance fixture should produce matches"
    )
end

local completion_items = assert_budget(
    "completion",
    budgets.completion,
    function()
        return typst.completion.complete({
            base = "table",
            context = "markup",
            include_tinymist = false,
            limit = 50,
        })
    end
)
assert(
    has_item(completion_items, function(item)
        return item.word == "table"
    end),
    "completion performance fixture should include stdlib completions"
)

perf.write(spec_name)
vim.env.TYPST_PACKAGE_CACHE_PATH = old_package_cache_path
vim.cmd("qa!")
