#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

runs="${TYPST_NVIM_BENCHMARK_RUNS:-3}"
bench_root="${TYPST_NVIM_BENCHMARK_ROOT:-$(typst_nvim_test_cache_path benchmark-reports)/$(date -u +%Y%m%dT%H%M%SZ)}"

specs=(
  tests/performance/performance_spec.lua
  tests/performance/large_project_performance_spec.lua
)

for run in $(seq 1 "${runs}"); do
  report_dir="${bench_root}/run-${run}"
  mkdir -p "${report_dir}"
  for spec in "${specs[@]}"; do
    echo "==> benchmark run ${run}/${runs}: ${spec}"
    TYPST_NVIM_PERF_REPORT_DIR="${report_dir}" \
      TYPST_NVIM_PERF_BUDGET_SCALE="${TYPST_NVIM_PERF_BUDGET_SCALE:-1}" \
      nvim --headless -u tests/minimal_init.lua -l "${spec}"
  done
done

TYPST_NVIM_BENCHMARK_ROOT="${bench_root}" \
  nvim --headless -u tests/minimal_init.lua -l tests/summarize_benchmarks.lua
