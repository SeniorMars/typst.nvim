#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

specs=()
while IFS= read -r spec; do
  specs+=("${spec}")
done < <(find tests/policy -name '*_spec.lua' -type f | sort)

if [[ "${#specs[@]}" == "0" ]]; then
  echo "No policy specs found under tests/policy" >&2
  exit 1
fi

for spec in "${specs[@]}"; do
  echo "==> ${spec}"
  nvim --headless -n -u tests/minimal_init.lua -l "${spec}"
done
