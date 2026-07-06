#!/usr/bin/env bash
set -euo pipefail

typst_nvim_xdg_home() {
  case "${1:-}" in
    cache)
      printf '%s\n' "${XDG_CACHE_HOME:-${HOME}/.cache}"
      ;;
    config)
      printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}"
      ;;
    data)
      printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}"
      ;;
    state)
      printf '%s\n' "${XDG_STATE_HOME:-${HOME}/.local/state}"
      ;;
    *)
      printf 'usage: typst_nvim_xdg_home cache|config|data|state\n' >&2
      return 2
      ;;
  esac
}

typst_nvim_test_root_path() {
  local root="${TYPST_NVIM_TEST_ROOT:-$(typst_nvim_xdg_home cache)/nvim/typst.nvim-test}"
  if [[ "$#" -gt 0 ]]; then
    printf '%s/%s\n' "${root%/}" "$*"
  else
    printf '%s\n' "${root%/}"
  fi
}

typst_nvim_test_cache_path() {
  local root="${TYPST_NVIM_TEST_CACHE_ROOT:-$(typst_nvim_xdg_home cache)/nvim/typst.nvim}"
  if [[ "$#" -gt 0 ]]; then
    printf '%s/%s\n' "${root%/}" "$*"
  else
    printf '%s\n' "${root%/}"
  fi
}

typst_nvim_init_isolated_xdg() {
  local root="${TYPST_NVIM_TEST_XDG_ROOT:-}"
  if [[ -z "${root}" ]]; then
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
      root="${RUNNER_TEMP%/}/typst-nvim-xdg"
    else
      local base="${TMPDIR:-/tmp}"
      base="${base%/}"
      if command -v mktemp >/dev/null 2>&1; then
        root="$(mktemp -d "${base}/typst-nvim-xdg.XXXXXX")"
      else
        root="${base}/typst-nvim-xdg-${$}"
      fi
    fi
  fi

  mkdir -p "${root}"
  root="$(cd "${root}" && pwd -P)"

  export TYPST_NVIM_TEST_ROOT="${root}"
  export TYPST_NVIM_TEST_XDG_ROOT="${root}"
  export XDG_STATE_HOME="${root}/state"
  export XDG_DATA_HOME="${root}/data"
  export XDG_CACHE_HOME="${root}/cache"
  export XDG_CONFIG_HOME="${root}/config"

  mkdir -p \
    "${root}" \
    "${XDG_STATE_HOME}" \
    "${XDG_DATA_HOME}" \
    "${XDG_CACHE_HOME}" \
    "${XDG_CONFIG_HOME}"
}

typst_nvim_init_test_xdg() {
  if [[ "${TYPST_NVIM_TEST_ISOLATE_XDG:-0}" == "1" ]]; then
    typst_nvim_init_isolated_xdg
    return
  fi

  local root
  root="$(typst_nvim_test_root_path)"
  mkdir -p "${root}" "$(typst_nvim_test_cache_path)"
  root="$(cd "${root}" && pwd -P)"

  export TYPST_NVIM_TEST_ROOT="${root}"
  # Compatibility for tests that still read the old variable. This is now a
  # test scratch root inside the real XDG cache, not a replacement XDG home.
  export TYPST_NVIM_TEST_XDG_ROOT="${root}"
}
