#!/usr/bin/env bash
set -euo pipefail

typst_nvim_init_test_xdg() {
  if [[ -z "${TYPST_NVIM_TEST_XDG_ROOT:-}" ]]; then
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
      TYPST_NVIM_TEST_XDG_ROOT="${RUNNER_TEMP%/}/typst-nvim-xdg"
    else
      local base="${TMPDIR:-/tmp}"
      base="${base%/}"
      if command -v mktemp >/dev/null 2>&1; then
        TYPST_NVIM_TEST_XDG_ROOT="$(mktemp -d "${base}/typst-nvim-xdg.XXXXXX")"
      else
        TYPST_NVIM_TEST_XDG_ROOT="${base}/typst-nvim-xdg-${$}"
      fi
    fi
    export TYPST_NVIM_TEST_XDG_ROOT
  fi

  mkdir -p "${TYPST_NVIM_TEST_XDG_ROOT}"
  TYPST_NVIM_TEST_XDG_ROOT="$(cd "${TYPST_NVIM_TEST_XDG_ROOT}" && pwd -P)"
  export TYPST_NVIM_TEST_XDG_ROOT

  export XDG_STATE_HOME="${TYPST_NVIM_TEST_XDG_ROOT}/state"
  export XDG_DATA_HOME="${TYPST_NVIM_TEST_XDG_ROOT}/data"
  export XDG_CACHE_HOME="${TYPST_NVIM_TEST_XDG_ROOT}/cache"
  export XDG_CONFIG_HOME="${TYPST_NVIM_TEST_XDG_ROOT}/config"

  mkdir -p \
    "${TYPST_NVIM_TEST_XDG_ROOT}" \
    "${XDG_STATE_HOME}" \
    "${XDG_DATA_HOME}" \
    "${XDG_CACHE_HOME}" \
    "${XDG_CONFIG_HOME}"
}
