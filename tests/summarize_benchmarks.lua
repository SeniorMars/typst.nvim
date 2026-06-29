local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local report_root = vim.env.TYPST_NVIM_BENCHMARK_ROOT
    or typst_test_cache_path("benchmark-reports")
local summary, path =
    require("tests.benchmark_report_summary").write(report_root)

print(
    ("benchmark summary: %d metrics across %d runs -> %s"):format(
        #summary.metrics,
        #summary.runs,
        path
    )
)
vim.cmd("qa!")
