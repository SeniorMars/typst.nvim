local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local summary = require("tests.benchmark_report_summary")
local util = require("typst.core.util")

local report_root = typst_test_cache_path("benchmark-summary-spec")
vim.fn.delete(report_root, "rf")
vim.fn.mkdir(report_root .. "/run-1", "p")
vim.fn.mkdir(report_root .. "/run-2", "p")

local function write(path, payload)
    local ok, err = util.atomic_writefile({ vim.json.encode(payload) }, path)
    assert(ok, "failed to write fixture report: " .. vim.inspect(err))
end

write(report_root .. "/run-1/performance_spec.json", {
    spec = "performance_spec",
    metrics = {
        {
            name = "completion",
            elapsed_ms = 10,
            budget_ms = 100,
        },
        {
            name = "toc_p95",
            p95_ms = 20,
            budget_ms = 200,
        },
    },
})
write(report_root .. "/run-2/performance_spec.json", {
    spec = "performance_spec",
    metrics = {
        {
            name = "completion",
            elapsed_ms = 30,
            budget_ms = 100,
        },
        {
            name = "toc_p95",
            p95_ms = 40,
            budget_ms = 200,
        },
    },
})
local collected = summary.collect(report_root)
assert(#collected.runs == 2, "benchmark summary should record runs")

local by_name = {}
for _, metric in ipairs(collected.metrics) do
    by_name[metric.name] = metric
end

assert(by_name.completion, "completion metric should be summarized")
assert(by_name.completion.samples == 2, "completion should have two samples")
assert(by_name.completion.p50_ms == 10, "p50 should use sorted samples")
assert(by_name.completion.p95_ms == 30, "p95 should use sorted samples")
assert(by_name.completion.worst_ratio == 0.3, "worst ratio should be tracked")

assert(by_name.toc_p95, "p95-only metric should be summarized")
assert(by_name.toc_p95.max_ms == 40, "p95-only max should be tracked")

local _, path = summary.write(report_root)
assert(vim.fn.filereadable(path) == 1, "summary file should be written")

vim.cmd("qa!")
