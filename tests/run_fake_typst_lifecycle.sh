#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

nvim --headless -n -u tests/minimal_init.lua -l tests/integration/compiler/fake_typst_integration_spec.lua
