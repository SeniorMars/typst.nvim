#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

typst_parser_available=0
if nvim --headless -n -u tests/minimal_init.lua \
  -c 'lua vim.api.nvim_buf_set_lines(0, 0, -1, false, {"$ alpha $"}) vim.bo.filetype = "typst" local ok_parser, parser = pcall(vim.treesitter.get_parser, 0, "typst") local ok_query, query = pcall(vim.treesitter.query.get, "typst", "conceal") if ok_parser and parser and ok_query and query then vim.cmd("qa!") else vim.cmd("cquit") end' \
  >/dev/null 2>&1; then
  typst_parser_available=1
fi

if [[ "${TYPST_NVIM_REQUIRE_TREESITTER:-0}" == "1" && "${typst_parser_available}" != "1" ]]; then
  echo "Typst Tree-sitter parser/query is required but unavailable or incompatible" >&2
  exit 1
fi

specs=()

while IFS= read -r spec; do
  specs+=("${spec}")
done < <(find tests/unit -name '*_spec.lua' -type f | sort)

if [[ "${#specs[@]}" == "0" ]]; then
  echo "No unit specs found under tests/unit" >&2
  exit 1
fi

parser_specs=(
  tests/unit/conceal_spec.lua
  tests/unit/motions_spec.lua
  tests/unit/textobjects_spec.lua
  tests/unit/transform_spec.lua
  tests/unit/repeat_spec.lua
  tests/unit/queries_spec.lua
  tests/unit/parser_compat_spec.lua
)

is_parser_spec() {
  local candidate="$1"
  local parser_spec
  for parser_spec in "${parser_specs[@]}"; do
    if [[ "${candidate}" == "${parser_spec}" ]]; then
      return 0
    fi
  done
  return 1
}

for spec in "${specs[@]}"; do
  if [[ "${typst_parser_available}" != "1" ]] && is_parser_spec "${spec}"; then
    echo "==> ${spec} (skipped: compatible Typst Tree-sitter parser/query unavailable)"
    continue
  fi

  echo "==> ${spec}"
  nvim --headless -n -u tests/minimal_init.lua -l "${spec}"
done
