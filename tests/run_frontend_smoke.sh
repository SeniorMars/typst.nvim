#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

echo "==> tests/integration/completion_frontends/completion_frontend_integration_spec.lua"
nvim --headless -u tests/minimal_init.lua -l tests/integration/completion_frontends/completion_frontend_integration_spec.lua

echo "==> tests/integration/completion_frontends/completion_frontend_popup_spec.lua"
TYPST_NVIM_FRONTEND_POPUP_E2E="${TYPST_NVIM_FRONTEND_POPUP_E2E:-0}" \
  nvim --headless -u tests/minimal_init.lua -l tests/integration/completion_frontends/completion_frontend_popup_spec.lua

bash tests/run_playwright_smoke.sh
