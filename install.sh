#!/usr/bin/env bash

set -e

# get current version from Cargo.toml
get_version() {
  grep '^version =' Cargo.toml | sed -E 's/.*"([^"]+)".*/\1/'
}

# compile from source
build() {
  echo "Building typst.nvim from source..."

  cargo build --release --target-dir ./target

  # Place the compiled library where Neovim can find it.
  mkdir -p lua

  if [ "$(uname)" == "Darwin" ]; then
    mv target/release/libtypst.dylib lua/typst.so
  fi

  if [ "$(cut -c 1-5 <<< $(uname -s))" == "Linux" ]; then
    mv target/release/libtypst.so lua/typst.so
  elif [ "$(cut -c 1-10 <<< $(uname -s))" == "MINGW64_NT" ]; then
    mv target/release/typst.dll lua/typst.dll
  fi
}

case "$1" in
  build)
    build
    ;;
  *)
    version="v$(get_version)"
    echo "Unknown command: $1"
    ;;
esac