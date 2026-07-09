#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

suite="${TYPST_NVIM_PROVIDER_SUITE:-all}"

compiler_specs=(
  tests/unit/provider_contract_spec.lua
  tests/unit/provider_sdk_matrix_spec.lua
  tests/unit/pending_handle_spec.lua
  tests/unit/provider_adapter_spec.lua
  tests/unit/provider_adapter_cancel_style_spec.lua
  tests/unit/provider_adapter_late_duplicate_spec.lua
  tests/unit/provider_adapter_invalid_handle_spec.lua
  tests/unit/provider_adapter_handle_classification_spec.lua
  tests/integration/compiler/provider_spec.lua
  tests/unit/provider_api_spec.lua
  tests/integration/compiler/generic_provider_spec.lua
  tests/integration/compiler/generic_invalid_output_path_spec.lua
)

async_specs=(
  tests/integration/compiler/provider_async_spec.lua
  tests/integration/compiler/provider_restart_cancel_spec.lua
  tests/unit/async_cancel_spec.lua
  tests/integration/compiler/lifecycle_spec.lua
  tests/integration/watch/process_spec.lua
)

workflow_specs=(
  tests/unit/export_spec.lua
  tests/unit/export_epoch_token_spec.lua
  tests/unit/workflow_safe_output_path_spec.lua
  tests/integration/render/render_spec.lua
  tests/unit/render_generation_spec.lua
  tests/unit/output_policy_spec.lua
)

tools_viewer_specs=(
  tests/integration/viewer_spec.lua
  tests/integration/tinymist/stale_callbacks_spec.lua
  tests/unit/tinymist_format_async_spec.lua
  tests/unit/format_async_spec.lua
  tests/unit/format_lint_spec.lua
  tests/unit/lint_generation_spec.lua
)

case "${suite}" in
  compiler)
    specs=("${compiler_specs[@]}")
    ;;
  async)
    specs=("${async_specs[@]}")
    ;;
  workflow)
    specs=("${workflow_specs[@]}")
    ;;
  tools-viewer)
    specs=("${tools_viewer_specs[@]}")
    ;;
  all)
    specs=(
      "${compiler_specs[@]}"
      "${async_specs[@]}"
      "${workflow_specs[@]}"
      "${tools_viewer_specs[@]}"
    )
    ;;
  *)
    echo "unknown provider suite: ${suite}" >&2
    exit 1
    ;;
esac

for spec in "${specs[@]}"; do
  echo "==> ${spec}"
  nvim --headless -n -u tests/minimal_init.lua -l "${spec}"
done
