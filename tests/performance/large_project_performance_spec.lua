local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local conceal = require("typst.conceal")
local perf = require("tests.performance_report")
local toc = require("typst.navigation.toc")
local telemetry = require("typst.core.telemetry")
local typst = require("typst")

local old_package_cache_path = vim.env.TYPST_PACKAGE_CACHE_PATH
local fixture_root = typst_test_cache_path("large-project-performance")
local package_root = root .. "/tests/fixtures/packages"

local spec_name = "large_project_performance_spec"
local scale = perf.scale()
local budgets = {
    large_index_collect = 8000 * scale,
    large_index_cached = 500 * scale,
    large_index_headings = 200 * scale,
    large_completion = 1500 * scale,
    large_package_refresh = 2000 * scale,
    large_package_scan_batch_p95 = 250 * scale,
    large_package_completion = 1000 * scale,
    large_package_completion_p95 = 500 * scale,
    first_package_lookup_miss = 1500 * scale,
    large_toc_p95 = 1500 * scale,
    large_toc_follow_coalescing = 200 * scale,
    large_picker_p95 = 2000 * scale,
    large_conceal_first_render = 3000 * scale,
    large_conceal_redraw_p95 = 500 * scale,
    large_bibliography_diagnostics = 3000 * scale,
}

local function assert_budget(name, fn)
    local budget = budgets[name]
    local result = perf.assert_budget(spec_name, name, budget, fn)
    return result
end

local function assert_p95(name, samples, fn)
    local budget = budgets[name]
    local result = perf.assert_p95_budget(spec_name, name, budget, samples, fn)
    return result
end

local function writefile(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
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

vim.fn.delete(fixture_root, "rf")
vim.fn.mkdir(fixture_root .. "/chapters", "p")

local main_lines = {
    '#import "chapters/part-001.typ": *',
    '#bibliography("refs.bib")',
    "",
    "= Large Project Fixture <sec:large-root>",
    "",
    "#cite(<ref-001>)",
    "Text $ alpha + arrow.r + RR + x_1 + y^2 $ end.",
}

for i = 2, 72 do
    main_lines[#main_lines + 1] = ('#import "chapters/part-%03d.typ": *'):format(
        i
    )
end

for i = 1, 72 do
    local part_lines = {
        ("= Section %03d <sec:large-%03d>"):format(i, i),
        "",
        ("#let local-fn-%03d(value) = value"):format(i),
        ("#figure(rect(width: 1pt, height: 1pt), caption: [Figure %03d]) <fig:large-%03d>"):format(
            i,
            i
        ),
        ("#cite(<ref-%03d>)"):format(i),
        "Text $ alpha + arrow.r + RR + x_1 + y^2 $ end.",
        "",
        ("== Nested Section %03d <sec:large-%03d-nested>"):format(i, i),
        ("#let local-value-%03d = %d"):format(i, i),
    }
    writefile(("%s/chapters/part-%03d.typ"):format(fixture_root, i), part_lines)
end

local bib_lines = {}
for i = 1, 96 do
    bib_lines[#bib_lines + 1] = ("@article{ref-%03d,"):format(i)
    bib_lines[#bib_lines + 1] = ("  title = {Large Fixture Reference %03d},"):format(
        i
    )
    bib_lines[#bib_lines + 1] = ("  author = {Author, Test %03d},"):format(i)
    bib_lines[#bib_lines + 1] = "  year = {2026},"
    bib_lines[#bib_lines + 1] = "}"
end

local main = fixture_root .. "/main.typ"
writefile(main, main_lines)
writefile(fixture_root .. "/refs.bib", bib_lines)

vim.env.TYPST_PACKAGE_CACHE_PATH = package_root

typst.reset()
typst.setup({
    root = fixture_root,
    output_dir = typst_test_cache_path("large-project-output"),
    completion = {
        include_fonts = false,
        package_cache_prewarm = false,
        package_scan_max = 500,
        package_cache_ttl_ms = 60000,
    },
})
local package_completion = require("typst.completion.packages")
local package_provider = require("typst.package")
package_completion.reset()
package_provider.reset()
telemetry.reset()
assert_budget("large_package_refresh", function()
    package_completion.prewarm({
        force = true,
        schedule = true,
        ttl_ms = 60000,
    })
    assert(
        vim.wait(5000, function()
            local records = package_provider.cached_packages({
                roots = { package_root },
                prefix = "@preview/cetz",
                max = 1,
                memory_only = true,
                schedule_refresh = false,
            })
            return #records > 0
        end, 10),
        "scheduled package prewarm should populate package records"
    )
    return true
end)
local package_scan_batch = assert(
    telemetry.snapshot()["package.scan_batch"],
    "missing package scan batch telemetry"
)
assert(
    package_scan_batch.p95_ms <= budgets.large_package_scan_batch_p95,
    ("package prewarm batch p95 exceeded %.1fms budget: %.1fms"):format(
        budgets.large_package_scan_batch_p95,
        package_scan_batch.p95_ms
    )
)
print(
    ("package prewarm batch p95 %.1fms <= %.1fms"):format(
        package_scan_batch.p95_ms,
        budgets.large_package_scan_batch_p95
    )
)
perf.record_metric(spec_name, {
    name = "large_package_scan_batch_p95",
    p95_ms = package_scan_batch.p95_ms,
    budget_ms = budgets.large_package_scan_batch_p95,
    ratio = package_scan_batch.p95_ms / budgets.large_package_scan_batch_p95,
    samples = package_scan_batch.sample_count,
})
vim.cmd.edit(vim.fn.fnameescape(main))
vim.bo.filetype = "typst"
local project = assert(typst.project.attach(0), "large fixture should attach")

typst.index.reset(project)
telemetry.reset()

local collected = assert_budget("large_index_collect", function()
    return typst.index.collect({ project = project })
end)
assert(#collected.headings >= 100, "large fixture should expose many headings")
assert(
    has_item(collected.labels, function(item)
        return item.name == "sec:large-072"
    end),
    "large fixture should expose imported labels"
)

local cached = assert_budget("large_index_cached", function()
    return typst.index.collect({ project = project })
end)
assert(#cached.labels >= 100, "cached large index should preserve labels")

local headings = assert_budget("large_index_headings", function()
    return typst.index.headings(project)
end)
assert(#headings >= 100, "narrow heading accessor should return headings")

local large_toc_items = assert_p95("large_toc_p95", 5, function()
    return toc.collect(project, { backend = "treesitter" })
end)
assert(#large_toc_items >= 100, "large TOC p95 fixture should expose headings")

local nav_toc = require("typst.navigation.toc")
local old_is_open = nav_toc.is_open
local old_follow = nav_toc.follow
local follow_calls = 0
rawset(nav_toc, "is_open", function(attached)
    return attached == project
end)
rawset(nav_toc, "follow", function(attached, follow_bufnr)
    assert(attached == project, "large TOC follow should keep project context")
    assert(
        follow_bufnr == vim.api.nvim_get_current_buf(),
        "large TOC follow should target source buffer"
    )
    follow_calls = follow_calls + 1
    return true
end)
local follow_ok, follow_err = xpcall(function()
    telemetry.reset()
    assert_budget("large_toc_follow_coalescing", function()
        for _ = 1, 100 do
            nav_toc.schedule_follow(project, vim.api.nvim_get_current_buf(), {
                delay_ms = 1,
            })
        end
        assert(
            vim.wait(1000, function()
                return follow_calls == 1
            end, 5),
            "large TOC follow should coalesce cursor burst into one follow"
        )
        return follow_calls
    end)
    local follow_telemetry = telemetry.snapshot()
    assert(
        follow_telemetry["toc.follow.coalesced"]
            and follow_telemetry["toc.follow.coalesced"].count >= 99,
        "large TOC follow should report coalesced cursor events"
    )
    assert(
        follow_telemetry["toc.follow.execute"]
            and follow_telemetry["toc.follow.execute"].count == 1,
        "large TOC follow should report one executed follow"
    )
end, debug.traceback)
nav_toc.is_open = old_is_open
nav_toc.follow = old_follow
if not follow_ok then
    error(follow_err)
end

local large_picker_items = assert_p95("large_picker_p95", 5, function()
    return typst.picker.items({
        project = project,
        kind = "all",
        toc_backend = "treesitter",
    })
end)
assert(
    #large_picker_items >= 100,
    "large picker p95 fixture should expose project items"
)

conceal.refresh(vim.api.nvim_get_current_buf())
local first_conceal_matches = assert_budget(
    "large_conceal_first_render",
    function()
        return conceal.matches(vim.api.nvim_get_current_buf())
    end
)
if has_compatible_typst_conceal_query(vim.api.nvim_get_current_buf()) then
    assert(
        #first_conceal_matches > 0,
        "large conceal first render should produce matches"
    )
end

assert_p95("large_conceal_redraw_p95", 5, function()
    return conceal._window_matches(
        vim.api.nvim_get_current_buf(),
        vim.api.nvim_get_current_win(),
        { topline = 0, botline = math.min(60, vim.api.nvim_buf_line_count(0)) }
    )
end)
local conceal_window_metric = assert(
    telemetry.snapshot()["conceal.window_matches"],
    "missing conceal window-match telemetry"
)
assert(
    conceal_window_metric.p95_ms <= budgets.large_conceal_redraw_p95,
    ("conceal window-match telemetry p95 exceeded %.1fms budget: %.1fms"):format(
        budgets.large_conceal_redraw_p95,
        conceal_window_metric.p95_ms
    )
)
perf.record_metric(spec_name, {
    name = "large_conceal_window_matches_telemetry_p95",
    p95_ms = conceal_window_metric.p95_ms,
    budget_ms = budgets.large_conceal_redraw_p95,
    ratio = conceal_window_metric.p95_ms / budgets.large_conceal_redraw_p95,
    samples = conceal_window_metric.sample_count,
})
local completion_items = assert_budget("large_completion", function()
    return typst.completion.complete({
        base = "local-fn-07",
        context = "markup",
        include_tinymist = false,
        include_packages = false,
        limit = 50,
        project = project,
    })
end)
assert(
    has_item(completion_items, function(item)
        return item.word == "local-fn-070"
            or item.word == "local-fn-071"
            or item.word == "local-fn-072"
    end),
    "large fixture completion should use project symbols"
)

local package_items = assert_budget("large_package_completion", function()
    return typst.completion.complete({
        base = "@preview/cetz",
        context = "markup",
        include_tinymist = false,
        include_packages = true,
        package_memory_only = true,
        limit = 20,
    })
end)
assert(
    has_item(package_items, function(item)
        return item.word and item.word:find("@preview/cetz", 1, true)
    end),
    "package completion should serve cached package records"
)

local cold_package_provider = require("typst.package.cache")
cold_package_provider.reset()
local cold_package_items = assert_budget("first_package_lookup_miss", function()
    return typst.completion.complete({
        base = "@preview/cetz",
        context = "markup",
        include_tinymist = false,
        include_packages = true,
        package_memory_only = true,
        limit = 20,
    })
end)
assert(
    #cold_package_items == 0,
    "first package completion after cache miss should return immediately with no stale records"
)
assert(
    vim.wait(5000, function()
        local records = package_provider.cached_packages({
            roots = { package_root },
            prefix = "@preview/cetz",
            max = 1,
            memory_only = true,
            schedule_refresh = false,
        })
        return #records > 0
    end, 10),
    "first package completion after cache miss should schedule cache refresh"
)

local package_completion_p95 = assert_p95(
    "large_package_completion_p95",
    8,
    function()
        return typst.completion.complete({
            base = "@preview/cetz",
            context = "markup",
            include_tinymist = false,
            include_packages = true,
            package_memory_only = true,
            limit = 20,
        })
    end
)
assert(
    has_item(package_completion_p95, function(item)
        return item.word and item.word:find("@preview/cetz", 1, true)
    end),
    "package completion p95 hot path should serve cached package records"
)

local bibliography_result = assert_budget(
    "large_bibliography_diagnostics",
    function()
        return typst.bibliography.diagnostics({
            project = project,
            quickfix = false,
            open = false,
        })
    end
)
assert(
    bibliography_result and bibliography_result.ok,
    "large bibliography diagnostics should complete"
)

for _, line in ipairs(telemetry.report()) do
    print(line)
end

perf.write(spec_name)
vim.env.TYPST_PACKAGE_CACHE_PATH = old_package_cache_path
vim.cmd("qa!")
