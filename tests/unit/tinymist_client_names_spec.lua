local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local clients = require("typst.integrations.tinymist.clients")

typst.reset({ force = true })
typst.setup({
    integrations = {
        tinymist = {
            lsp = "detect",
        },
    },
})
local original_get_clients = vim.lsp.get_clients
local original_start = vim.lsp.start
local ok, err = pcall(function()
    rawset(vim.lsp, "get_clients", function()
        return {
            {
                id = 10,
                name = "tinymist_custom",
                config = {
                    root_dir = vim.fn.getcwd(),
                },
            },
        }
    end)
    assert(
        #clients.clients(0) == 0,
        "custom Tinymist client names should not match by default"
    )

    typst.setup({
        integrations = {
            tinymist = {
                lsp = "detect",
                client_names = { "tinymist_custom" },
            },
        },
    })
    local matched = clients.clients(0)
    assert(
        #matched == 1 and matched[1].name == "tinymist_custom",
        "configured Tinymist client names should be detected"
    )

    local started_clients = {}
    local start_count = 0
    rawset(vim.lsp, "get_clients", function()
        return started_clients
    end)
    rawset(vim.lsp, "start", function(config, opts)
        start_count = start_count + 1
        started_clients[1] = {
            id = start_count,
            name = config.name,
            config = {
                root_dir = config.root_dir,
            },
        }
        assert(
            opts.reuse_client(started_clients[1], config),
            "typst.nvim-started tinymist client should be reusable even with custom names"
        )
        return start_count
    end)
    typst.setup({
        integrations = {
            tinymist = {
                lsp = "start",
                path = vim.v.progpath,
                client_names = { "tinymist_custom" },
            },
        },
    })
    local project = {
        root = vim.fn.getcwd(),
    }
    local first_ok, first_reason = clients.ensure(0, project)
    assert(
        first_ok and first_reason == "started",
        "Tinymist start mode should start a default-named tinymist client"
    )
    local second_ok, second_reason = clients.ensure(0, project)
    assert(
        second_ok and second_reason == "attached",
        "subsequent ensure should detect the default-named started client"
    )
    assert(
        start_count == 1,
        "ensure should not start duplicate Tinymist clients"
    )
end)
vim.lsp.get_clients = original_get_clients
vim.lsp.start = original_start
assert(ok, err)
