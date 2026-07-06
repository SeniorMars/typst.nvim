local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local health = require("typst.health")
local tinymist = require("typst.integrations.tinymist")
local typst = require("typst")

local old_health = vim.health
local old_coc_initialized = vim.g.coc_service_initialized
local old_disable_autostart = vim.g.typst_nvim_disable_tinymist_autostart

local function capture_health()
    local captured = {
        ok = {},
        warn = {},
        error = {},
        info = {},
        start = {},
    }
    rawset(vim, "health", {
        start = function(message)
            captured.start[#captured.start + 1] = message
        end,
        ok = function(message)
            captured.ok[#captured.ok + 1] = message
        end,
        warn = function(message)
            captured.warn[#captured.warn + 1] = message
        end,
        error = function(message)
            captured.error[#captured.error + 1] = message
        end,
        info = function(message)
            captured.info[#captured.info + 1] = message
        end,
    })
    return captured
end

local function contains(lines, needle)
    for _, line in ipairs(lines or {}) do
        if line:find(needle, 1, true) then
            return true
        end
    end
    return false
end

local ok, err = xpcall(function()
    vim.g.coc_service_initialized = nil
    vim.g.typst_nvim_disable_tinymist_autostart = nil
    typst.reset({ force = true })
    typst.setup({
        completion = {
            package_cache_prewarm = false,
        },
        integrations = {
            tinymist = {
                lsp = "start",
                cmd = { "typst-nvim-missing-tinymist-test-binary" },
            },
        },
    })

    local missing = capture_health()
    health.check()
    assert(
        contains(missing.warn, "Tinymist startability: missing_executable"),
        "health should report missing Tinymist executable distinctly"
    )
    assert(
        contains(
            missing.ok,
            "Tinymist command: typst-nvim-missing-tinymist-test-binary"
        ),
        "health should report the configured Tinymist command"
    )
    local missing_start = tinymist.startability()
    local missing_ok, missing_reason = tinymist.ensure(0)
    assert(
        missing_ok == false and missing_reason == missing_start.reason,
        "ensure should share missing-executable policy with startability"
    )

    typst.reset({ force = true })
    vim.g.coc_service_initialized = 1
    typst.setup({
        completion = {
            package_cache_prewarm = false,
        },
        integrations = {
            tinymist = {
                lsp = "auto",
                cmd = { "typst-nvim-missing-tinymist-test-binary" },
            },
        },
    })

    local coc = capture_health()
    health.check()
    assert(
        contains(coc.ok, "Tinymist startability: delegated to coc.nvim"),
        "health should report Coc delegation before executable probing"
    )
    local coc_start = tinymist.startability()
    local coc_ok, coc_reason = tinymist.ensure(0)
    assert(
        coc_ok == false and coc_reason == coc_start.reason,
        "ensure should share Coc delegation policy with startability"
    )
end, debug.traceback)

vim.health = old_health
vim.g.coc_service_initialized = old_coc_initialized
vim.g.typst_nvim_disable_tinymist_autostart = old_disable_autostart
typst.reset({ force = true })

if not ok then
    error(err)
end

vim.cmd("qa!")
