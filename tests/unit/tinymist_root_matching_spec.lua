local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local clients = require("typst.integrations.tinymist.clients")
local project_store = require("typst.project.store")
local typst = require("typst")

local original_get_clients = vim.lsp.get_clients
local original_start = vim.lsp.start

local project_a = {
    root = typst_test_cache_path("tinymist-root-a"),
    main = typst_test_cache_path("tinymist-root-a/main.typ"),
    bufs = {},
}
local project_b = {
    root = typst_test_cache_path("tinymist-root-b"),
    main = typst_test_cache_path("tinymist-root-b/main.typ"),
    bufs = {},
}
vim.fn.mkdir(project_a.root, "p")
vim.fn.mkdir(project_b.root, "p")

local bufnr = vim.api.nvim_create_buf(false, true)
project_b.bufs[bufnr] = true

local attached = {
    {
        id = 1,
        name = "tinymist",
        config = {
            root_dir = project_a.root,
        },
    },
}
local started = 0

local ok, err = xpcall(function()
    typst.reset({ force = true })
    typst.setup({
        integrations = {
            tinymist = {
                lsp = "start",
                path = vim.v.progpath,
            },
        },
    })

    local live_project_b = project_store.create(project_b.root, project_b.main)
    live_project_b.bufs[bufnr] = true
    project_store.set_buffer(bufnr, live_project_b.key)
    assert(
        clients.project_for_buffer(bufnr) == live_project_b,
        "Tinymist shared project helper should return the buffer's attached project"
    )
    local previous_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_current_buf(bufnr)
    assert(
        clients.normalize_bufnr(0) == bufnr,
        "Tinymist shared buffer normalizer should resolve 0 to the current buffer"
    )
    assert(
        clients.project_for_buffer(0) == live_project_b,
        "Tinymist shared project helper should normalize current buffer ids"
    )
    vim.api.nvim_set_current_buf(previous_buf)

    rawset(vim.lsp, "get_clients", function()
        return attached
    end)
    rawset(vim.lsp, "start", function(config, opts)
        started = started + 1
        assert(
            config.root_dir == project_b.root,
            "ensure should start Tinymist with the requested project root"
        )
        assert(
            opts.reuse_client(attached[1], config) == false,
            "wrong-root Tinymist client should not be reused"
        )
        attached[#attached + 1] = {
            id = 2,
            name = "tinymist",
            config = {
                root_dir = config.root_dir,
            },
        }
        return 2
    end)

    assert(
        clients.available(bufnr, project_a) == true,
        "project A should see its matching attached Tinymist client"
    )
    assert(
        clients.available(bufnr, project_b) == false,
        "project B should ignore a wrong-root Tinymist client"
    )
    local wrong_root = clients.select_client({
        bufnr = bufnr,
        project = project_b,
    })
    assert(
        wrong_root.ok == false and wrong_root.reason == "wrong_root",
        "central Tinymist selector should report wrong-root clients structurally"
    )
    local no_project = clients.select_client({ bufnr = bufnr })
    assert(
        no_project.ok == true and no_project.client == attached[1],
        "central Tinymist selector without a project should keep legacy client selection"
    )

    local ensure_ok, reason = clients.ensure(bufnr, project_b)
    assert(
        ensure_ok == true and reason == "started",
        "project B should start a root-correct Tinymist client"
    )
    assert(started == 1, "ensure should start exactly one replacement client")

    assert(
        clients.available(bufnr, project_b) == true,
        "project B should see the newly started matching client"
    )

    attached = {
        {
            id = 3,
            name = "tinymist",
            config = {},
        },
    }
    assert(
        clients.available(bufnr, project_b) == true,
        "rootless Tinymist clients remain compatible with explicit projects"
    )

    attached = {
        {
            id = 4,
            name = "tinymist",
            config = {
                root_dir = project_b.root,
            },
        },
    }
    local nil_root_config = {
        root_dir = nil,
        name = "tinymist",
    }
    assert(
        clients.root_compatible(attached[1], nil_root_config.root_dir)
            == false,
        "rootless startup should not reuse an arbitrary rooted client"
    )

    attached = {
        {
            id = 5,
            name = "tinymist",
            config = {
                root_dir = project_b.root,
            },
            request = function() end,
            supports_method = function()
                return false
            end,
        },
    }
    local unsupported = clients.select_client({
        bufnr = bufnr,
        project = project_b,
        method = "workspace/symbol",
        request = "async",
    })
    assert(
        unsupported.ok == false and unsupported.reason == "unsupported",
        "central Tinymist selector should report unsupported methods structurally"
    )

    attached = {}
    local missing = clients.select_client({
        bufnr = bufnr,
        project = project_b,
    })
    assert(
        missing.ok == false and missing.reason == "no_client",
        "central Tinymist selector should report missing clients structurally"
    )

    typst.reset({ force = true })
    typst.setup({
        integrations = {
            tinymist = {
                lsp = "off",
            },
        },
    })
    attached = {
        {
            id = 6,
            name = "tinymist",
            config = {
                root_dir = project_b.root,
            },
        },
    }
    local lsp_off = clients.select_client({
        bufnr = bufnr,
        project = project_b,
    })
    assert(
        lsp_off.ok == false and lsp_off.reason == "lsp_off",
        "central Tinymist selector should report disabled LSP structurally"
    )
end, debug.traceback)

vim.lsp.get_clients = original_get_clients
vim.lsp.start = original_start
typst.reset({ force = true })

if not ok then
    error(err)
end

vim.cmd("qa!")
