#!/usr/bin/env bash
set -euo pipefail

source tests/xdg.sh
typst_nvim_init_test_xdg

repo="${GITHUB_WORKSPACE:-$(pwd)}"
lazy_path="${TYPST_NVIM_LAZY_PATH:-${repo}/.deps/lazy.nvim}"

if [[ ! -d "${lazy_path}" ]]; then
  echo "lazy.nvim not found at ${lazy_path}" >&2
  echo "Set TYPST_NVIM_LAZY_PATH or clone lazy.nvim before running this gate." >&2
  exit 1
fi

init_file="$(mktemp "${TMPDIR:-/tmp}/typst-nvim-lazy-init.XXXXXX.lua")"
trap 'rm -f "${init_file}"' EXIT

cat >"${init_file}" <<'LUA'
local repo = assert(vim.env.TYPST_NVIM_REPO, "TYPST_NVIM_REPO is required")
local lazy_path = assert(vim.env.TYPST_NVIM_LAZY_PATH, "TYPST_NVIM_LAZY_PATH is required")

vim.opt.runtimepath:prepend(lazy_path)

require("lazy").setup({
    {
        dir = repo,
        name = "typst.nvim",
        lazy = false,
        config = function()
            require("typst").setup({
                root = repo,
                output_dir = vim.fn.stdpath("cache") .. "/minimal-plugin-manager-output",
                allow_external_output = true,
                compile = {
                    deps = false,
                },
            })
        end,
    },
}, {
    root = vim.fn.stdpath("data") .. "/lazy",
    lockfile = vim.fn.stdpath("data") .. "/lazy-lock.json",
    install = {
        missing = false,
    },
    checker = {
        enabled = false,
    },
    change_detection = {
        enabled = false,
    },
    performance = {
        reset_packpath = false,
        rtp = {
            reset = false,
        },
    },
})

local typst = require("typst")
assert(typst.is_setup(), "typst.nvim should be setup by lazy.nvim")
assert(type(typst.project.attach) == "function", "project API should load")
assert(type(vim.api.nvim_get_commands({})["TypstWatch"]) == "table", "commands should register")
require("typst.health").check()

vim.cmd.edit(repo .. "/tests/fixtures/basic/main.typ")
local project = assert(
    typst.project.set_main(repo .. "/tests/fixtures/basic/main.typ"),
    "Typst project should attach through the public project API"
)
assert(project.main:match("main%.typ$"), "attached project should use fixture main")

vim.cmd("qa!")
LUA

TYPST_NVIM_REPO="${repo}" TYPST_NVIM_LAZY_PATH="${lazy_path}" \
  nvim --headless -n -u "${init_file}"
