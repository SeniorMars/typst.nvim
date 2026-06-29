#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

if [[ -z "${TYPST_NVIM_TEST_MINI:-}" && -d "${PWD}/.deps/mini.nvim" ]]; then
  export TYPST_NVIM_TEST_MINI="${PWD}/.deps/mini.nvim"
fi

if [[ "$#" -gt 0 ]]; then
  export TYPST_NVIM_MINITEST_FILES="$*"
fi

nvim --headless -n -u tests/minimal_init.lua -c "lua dofile('tests/run_minitest.lua')"
