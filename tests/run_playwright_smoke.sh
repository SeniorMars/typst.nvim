#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

if [[ -d "${PWD}/.deps/playwright-smoke/node_modules" ]]; then
  export NODE_PATH="${PWD}/.deps/playwright-smoke/node_modules${NODE_PATH:+:${NODE_PATH}}"
fi

if ! command -v node >/dev/null 2>&1; then
  if [[ "${TYPST_NVIM_REQUIRE_PLAYWRIGHT:-0}" == "1" ]]; then
    echo "node is required for Playwright smoke tests" >&2
    exit 1
  fi
  echo "==> Playwright native browser smoke skipped: node not found"
  exit 0
fi

echo "==> tests/playwright/native_browser_preview_smoke.js"
node tests/playwright/native_browser_preview_smoke.js
