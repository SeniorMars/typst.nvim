set positional-arguments

default:
  just --list

test:
  bash tests/run_unit.sh

minitest:
  bash tests/run_minitest.sh

integration:
  bash tests/run_integration.sh

policy:
  bash tests/run_policy.sh

stability-gate:
  bash tests/run_stability_gate.sh

lifecycle-matrix:
  bash tests/run_lifecycle_matrix.sh

docs-contract:
  bash tests/run_docs_contract.sh

performance-gate:
  bash tests/run_performance_gate.sh

benchmarks:
  bash tests/run_benchmark_suite.sh

startup-benchmark:
  bash tests/run_startup_benchmark.sh

windows-edge:
  bash tests/run_windows_edge.sh

luals:
  bash tests/run_luals.sh

frontend-smoke:
  bash tests/run_frontend_smoke.sh

playwright-smoke:
  bash tests/run_playwright_smoke.sh

provider-matrix:
  bash tests/run_provider_matrix.sh

preview-matrix *args:
  bash tests/run_preview_matrix.sh "$@"

api-stability:
  bash tests/run_api_stability.sh

config-docs:
  bash tests/run_config_docs.sh

metadata:
  cargo run --manifest-path tools/typst-metadata/Cargo.toml

fmt:
  stylua lua plugin ftplugin tests
  cargo fmt --manifest-path tools/typst-metadata/Cargo.toml

fmt-check:
  stylua --check lua plugin ftplugin tests
  cargo fmt --manifest-path tools/typst-metadata/Cargo.toml -- --check

health:
  bash -c 'source tests/xdg.sh; typst_nvim_init_test_xdg; nvim --headless -u tests/minimal_init.lua -c "checkhealth typst" -c qa'

check: test fmt-check health
