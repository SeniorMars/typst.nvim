set positional-arguments
alias t := test
alias tt := test_trace
alias b := build

default:
  just --list

install:
  ./install.sh

lint:
  cargo clippy --all-targets --all-features -- -D warnings

build:
  cargo build

test arg: build
  cargo test --package typst --lib -- $1 --exact --nocapture

test_trace $RUST_BACKTRACE="1" arg: build
  # will print a stack trace if it crashes
  cargo test --package typst --lib -- $1 --exact --nocapture

clean:
  cargo clean