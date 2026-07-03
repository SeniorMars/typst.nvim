#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

specs=(
  tests/unit/api_symbols_spec.lua
  tests/unit/api_spec_modules_exist_spec.lua
  tests/unit/commands_registration_spec.lua
  tests/unit/public_api_context_spec.lua
  tests/unit/project_public_snapshot_immutability_spec.lua
  tests/unit/cache_registry_spec.lua
  tests/policy/cache_registry_contract_spec.lua
  tests/policy/architecture_contract_spec.lua
  tests/unit/output_locks_policy_spec.lua
  tests/unit/diagnostics_buffer_limit_spec.lua
  tests/unit/provider_adapter_late_duplicate_spec.lua
  tests/unit/provider_adapter_invalid_handle_spec.lua
  tests/unit/operation_process_tree_cancel_spec.lua
  tests/integration/project/lifecycle_spec.lua
  tests/integration/compiler/lifecycle_spec.lua
  tests/integration/watch/process_spec.lua
  tests/integration/resources/supervisor_spec.lua
  tests/integration/preview/native_preview_fast_event_spec.lua
)

for spec in "${specs[@]}"; do
  echo "==> ${spec}"
  nvim --headless -n -u tests/minimal_init.lua -l "${spec}"
done
