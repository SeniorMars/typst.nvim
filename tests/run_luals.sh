#!/usr/bin/env bash
set -euo pipefail

if ! command -v lua-language-server >/dev/null 2>&1; then
  echo "lua-language-server is required for LuaLS diagnostics" >&2
  exit 1
fi

if ! command -v nvim >/dev/null 2>&1; then
  echo "nvim is required to locate Neovim runtime metadata" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to count LuaLS JSON diagnostics" >&2
  exit 1
fi

json_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

find_luals_meta() {
  local candidate
  local server

  if command -v brew >/dev/null 2>&1; then
    candidate="$(brew --prefix lua-language-server 2>/dev/null || true)"
    if [[ -n "${candidate}" && -d "${candidate}/libexec/meta/template" ]]; then
      printf '%s\n' "${candidate}/libexec/meta/template"
      return 0
    fi
  fi

  server="$(command -v lua-language-server)"
  server="$(cd "$(dirname "${server}")" && pwd -P)"
  for candidate in \
    "${server}/../libexec/meta/template" \
    "${server}/../share/lua-language-server/meta/template" \
    "${server}/../../share/lua-language-server/meta/template"; do
    if [[ -d "${candidate}" ]]; then
      (cd "${candidate}" && pwd -P)
      return 0
    fi
  done

  return 1
}

nvim_runtime="$(
  nvim --headless -n --clean \
    -c 'lua local runtime = vim.env.VIMRUNTIME; if runtime == nil or runtime == "" then runtime = vim.fn.expand("$VIMRUNTIME") end; io.write(runtime or "")' \
    -c 'qa!'
)"
if [[ -z "${nvim_runtime}" || ! -d "${nvim_runtime}/lua" ]]; then
  echo "could not locate Neovim runtime Lua metadata" >&2
  exit 1
fi

luals_meta="$(find_luals_meta || true)"
if [[ -z "${luals_meta}" ]]; then
  echo "could not locate LuaLS standard-library metadata" >&2
  exit 1
fi

out_dir="${TYPST_NVIM_LUALS_OUT:-.deps/luals-check}"
mkdir -p "${out_dir}/log" "${out_dir}/meta"

config="${out_dir}/.luarc.generated.json"
diagnostics="${out_dir}/diagnostics.json"

nvim_lua="$(json_string "${nvim_runtime}/lua")"
nvim_vim="$(json_string "${nvim_runtime}/lua/vim")"
luals_stdlib="$(json_string "${luals_meta}")"

cat >"${config}" <<JSON
{
  "Lua.runtime.version": "LuaJIT",
  "Lua.runtime.path": [
    "lua/?.lua",
    "lua/?/init.lua",
    "?.lua",
    "?/init.lua"
  ],
  "Lua.workspace.checkThirdParty": "Disable",
  "Lua.workspace.ignoreDir": [
    ".git",
    ".deps",
    "graphify-out"
  ],
  "Lua.workspace.library": [
    "${nvim_lua}",
    "${nvim_vim}",
    "${luals_stdlib}"
  ],
  "Lua.diagnostics.globals": [
    "vim",
    "describe",
    "it",
    "before_each",
    "after_each",
    "typst_test_root_path",
    "typst_test_cache_path",
    "typst_test_tmp_path",
    "typst_test_state_path"
  ],
  "Lua.telemetry.enable": false
}
JSON

rm -rf "${out_dir}/meta" "${out_dir}/log" "${diagnostics}"
mkdir -p "${out_dir}/meta" "${out_dir}/log"

lua-language-server \
  --check=. \
  --configpath="${config}" \
  --logpath="${out_dir}/log" \
  --metapath="${out_dir}/meta" \
  --checklevel=Warning \
  --check_format=json \
  --check_out_path="${diagnostics}"

count="$(
  jq -r '[to_entries[] | select(.value | type == "array") | .value[]] | length' \
    "${diagnostics}"
)"
if [[ "${count}" != "0" ]]; then
  echo "LuaLS diagnostics found: ${count}" >&2
  echo "See ${diagnostics}" >&2
  exit 1
fi

echo "LuaLS diagnostics clean"
