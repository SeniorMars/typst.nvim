#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

specs=(
  tests/unit/lifecycle_matrix_spec.lua
  tests/integration/project/lifecycle_spec.lua
  tests/integration/compiler/lifecycle_spec.lua
  tests/integration/watch/lifecycle_spec.lua
  tests/integration/watch/process_spec.lua
  tests/integration/preview/lifecycle_spec.lua
  tests/integration/resources/resource_manager_prune_spec.lua
)

for spec in "${specs[@]}"; do
  echo "==> ${spec}"
  nvim --headless -n -u tests/minimal_init.lua -l "${spec}"
done
