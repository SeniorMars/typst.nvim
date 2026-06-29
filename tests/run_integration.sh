#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

specs=()
while IFS= read -r spec; do
  specs+=("${spec}")
done < <(find tests/integration -name '*_spec.lua' -type f | sort)

if [[ "${#specs[@]}" == "0" ]]; then
  echo "No integration specs found under tests/integration" >&2
  exit 1
fi

for spec in "${specs[@]}"; do
  echo "==> ${spec}"
  nvim --headless -n -u tests/minimal_init.lua -l "${spec}"
done
