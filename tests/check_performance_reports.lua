local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local report_dir = vim.env.TYPST_NVIM_PERF_REPORT_DIR
    or typst_test_cache_path("performance-reports")

local required = {
    startup_spec = {
        "setup.default",
        "setup.optional_features",
    },
    performance_spec = {
        "project index collect",
        "project index cached collect",
        "TOC collect",
        "completion",
    },
    large_project_performance_spec = {
        "large_index_collect",
        "large_index_cached",
        "large_index_headings",
        "large_completion",
        "large_package_refresh",
        "large_package_completion",
        "large_toc_follow_coalescing",
        "large_conceal_window_matches_telemetry_p95",
        "large_bibliography_diagnostics",
    },
}

local function read_report(spec)
    local path = ("%s/%s.json"):format(report_dir, spec)
    assert(
        vim.fn.filereadable(path) == 1,
        "missing performance report: " .. path
    )
    local ok, decoded =
        pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    assert(
        ok and type(decoded) == "table",
        "invalid performance report: " .. path
    )
    return decoded
end

for spec, metrics in pairs(required) do
    local report = read_report(spec)
    local seen = {}
    for _, metric in ipairs(report.metrics or {}) do
        local value = metric.elapsed_ms or metric.p95_ms
        assert(
            type(value) == "number"
                and type(metric.budget_ms) == "number"
                and (metric.budget_ms <= 0 or value <= metric.budget_ms),
            "performance report contains failed metric: " .. vim.inspect(metric)
        )
        seen[metric.name] = true
    end

    for _, metric_name in ipairs(metrics) do
        assert(
            seen[metric_name],
            ("performance report %s missing metric %s"):format(
                spec,
                metric_name
            )
        )
    end
end

vim.cmd("qa!")
