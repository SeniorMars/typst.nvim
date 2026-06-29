#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

if [[ "${TYPST_NVIM_REQUIRE_WINDOWS:-0}" == "1" ]]; then
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
    *)
      echo "windows-edge gate requires an actual Windows runner" >&2
      exit 1
      ;;
  esac
fi

specs=(
  tests/unit/path_spec.lua
  tests/unit/unicode_paths_spec.lua
  tests/unit/process_spec.lua
  tests/integration/watch/process_spec.lua
  tests/unit/lifecycle_matrix_spec.lua
  tests/integration/project/lifecycle_spec.lua
  tests/unit/resolution_spec.lua
)

for spec in "${specs[@]}"; do
  echo "==> ${spec}"
  nvim --headless -u tests/minimal_init.lua -l "${spec}"
done
