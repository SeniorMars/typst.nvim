#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

nvim --headless -n -u tests/minimal_init.lua -l tests/generate_config_docs.lua
