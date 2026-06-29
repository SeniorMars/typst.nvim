#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

export TYPST_NVIM_PERF_REPORT_DIR="${TYPST_NVIM_PERF_REPORT_DIR:-${XDG_CACHE_HOME}/performance-reports}"
mkdir -p "${TYPST_NVIM_PERF_REPORT_DIR}"

nvim --headless -u tests/minimal_init.lua -l tests/performance/startup_spec.lua
