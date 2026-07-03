#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

export TYPST_NVIM_PERF_REPORT_DIR="${TYPST_NVIM_PERF_REPORT_DIR:-${XDG_CACHE_HOME}/performance-reports}"
mkdir -p "${TYPST_NVIM_PERF_REPORT_DIR}"

specs=(
  tests/performance/startup_spec.lua
  tests/performance/performance_spec.lua
  tests/performance/large_project_performance_spec.lua
)

for spec in "${specs[@]}"; do
  echo "==> ${spec}"
  TYPST_NVIM_PERF_STRICT="${TYPST_NVIM_PERF_STRICT:-1}" \
    nvim --headless -u tests/minimal_init.lua -l "${spec}"
done

nvim --headless -u tests/minimal_init.lua -l tests/check_performance_reports.lua
