#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

specs=(
  tests/unit/api_symbols_spec.lua
  tests/unit/api_spec_modules_exist_spec.lua
  tests/unit/commands_registration_spec.lua
  tests/unit/plug_mappings_spec.lua
  tests/policy/api_docs_contract_spec.lua
  tests/policy/config_docs_spec.lua
  tests/policy/docs_examples_spec.lua
  tests/policy/help_tags_spec.lua
  tests/unit/provider_contract_spec.lua
  tests/policy/parity_doc_spec.lua
  tests/policy/architecture_contract_spec.lua
  tests/policy/stability_docs_spec.lua
  tests/policy/state_inventory_spec.lua
)

for spec in "${specs[@]}"; do
  echo "==> ${spec}"
  nvim --headless -n -u tests/minimal_init.lua -l "${spec}"
done
