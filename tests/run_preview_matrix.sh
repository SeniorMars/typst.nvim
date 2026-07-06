#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg
mkdir -p "$(typst_nvim_test_root_path preview-matrix)"

case "${1:-browser-server}" in
  browser-server)
    mode="browser-server"
    opener="${2:-}"
    ;;
  browser-file)
    mode="browser-file"
    opener="${2:-}"
    ;;
  safari)
    mode="browser-server"
    opener="${2:-open -a Safari {url}}"
    ;;
  chrome)
    mode="browser-server"
    opener="${2:-open -a 'Google Chrome' {url}}"
    ;;
  firefox)
    mode="browser-server"
    opener="${2:-open -a Firefox {url}}"
    ;;
  preview)
    mode="viewer"
    opener="${2:-open -a Preview {url}}"
    ;;
  skim)
    mode="viewer"
    opener="${2:-open -a Skim {url}}"
    ;;
  sioyek)
    mode="viewer"
    opener="${2:-sioyek {url}}"
    ;;
  zathura)
    mode="viewer"
    opener="${2:-zathura {url}}"
    ;;
  okular)
    mode="viewer"
    opener="${2:-okular {url}}"
    ;;
  evince)
    mode="viewer"
    opener="${2:-evince {url}}"
    ;;
  mupdf)
    mode="viewer"
    opener="${2:-mupdf {url}}"
    ;;
  sumatrapdf)
    mode="viewer"
    opener="${2:-SumatraPDF.exe {url}}"
    ;;
  viewer)
    mode="viewer"
    opener="${2:-}"
    ;;
  *)
    cat >&2 <<'USAGE'
usage: tests/run_preview_matrix.sh [target] [opener]

targets:
  browser-server  browser-file  safari  chrome  firefox
  viewer          preview       skim    sioyek  zathura
  okular          evince        mupdf   sumatrapdf

The optional opener is a shell command containing {url}; for example:
  tests/run_preview_matrix.sh browser-server 'xdg-open {url}'
USAGE
    exit 2
    ;;
esac

TYPST_NVIM_PREVIEW_MATRIX_TARGET="${mode}" \
TYPST_NVIM_PREVIEW_MATRIX_OPEN="${opener}" \
nvim --headless -n -u tests/minimal_init.lua -l tests/manual_preview_matrix.lua
