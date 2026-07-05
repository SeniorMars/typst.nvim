local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local tinymist = require("typst.integrations.tinymist")
local tinymist_clients = require("typst.integrations.tinymist.clients")
local typst = require("typst")

local old_start = vim.lsp.start
local old_get_clients = vim.lsp.get_clients
local old_exists = vim.fn.exists
local old_coc_initialized = vim.g.coc_service_initialized
local old_disable_autostart = vim.g.typst_nvim_disable_tinymist_autostart

local function restore()
    vim.lsp.start = old_start
    vim.lsp.get_clients = old_get_clients
    vim.fn.exists = old_exists
    vim.g.coc_service_initialized = old_coc_initialized
    vim.g.typst_nvim_disable_tinymist_autostart = old_disable_autostart
end

vim.g.typst_nvim_disable_tinymist_autostart = nil
rawset(vim.lsp, "get_clients", function()
    return {}
end)
local starts = {}
rawset(vim.lsp, "start", function(config, opts)
    starts[#starts + 1] = { config = config, opts = opts }
    return #starts
end)
local attached_client = nil
local function on_attach() end

typst.reset()
typst.setup({
    root = root,
    integrations = {
        tinymist = {
            lsp = "auto",
            path = "ignored-tinymist",
            cmd = { "nvim", "--headless" },
            settings = { tinymist = { formatterMode = "typstyle" } },
            init_options = {
                cachePath = typst_test_cache_path("tinymist-cache"),
            },
            capabilities = {
                textDocument = {
                    completion = {
                        completionItem = {
                            snippetSupport = true,
                        },
                    },
                },
            },
            on_attach = on_attach,
        },
    },
})
local bufnr = vim.api.nvim_create_buf(false, true)
local started, reason = tinymist.ensure(bufnr, { root = root })
assert(started and reason == "started", "auto mode should start Tinymist")
assert(#starts == 1, "auto mode should call vim.lsp.start once")
assert(starts[1].config.name == "tinymist", "Tinymist client name is wrong")
assert(
    starts[1].config.root_dir == root,
    "Tinymist root_dir should be project root"
)
assert(
    starts[1].config.cmd[1] == "nvim",
    "Tinymist command should come from config"
)
assert(
    starts[1].opts.bufnr == bufnr,
    "Tinymist should attach to the requested buffer"
)
assert(
    starts[1].config.settings.tinymist.formatterMode == "typstyle",
    "Tinymist settings should be passed to vim.lsp.start"
)
assert(
    starts[1].config.init_options.cachePath
        == typst_test_cache_path("tinymist-cache"),
    "Tinymist init_options should be passed to vim.lsp.start"
)
assert(
    starts[1].config.capabilities.textDocument.completion.completionItem.snippetSupport
        == true,
    "Tinymist capabilities should be passed to vim.lsp.start"
)
assert(
    starts[1].config.on_attach == on_attach,
    "Tinymist on_attach should be passed to vim.lsp.start"
)
assert(
    starts[1].opts.reuse_client({
        name = "tinymist",
        config = {
            root_dir = root,
        },
    }, starts[1].config),
    "Tinymist should reuse an exact-root client"
)
assert(
    starts[1].opts.reuse_client({
        name = "tinymist",
        config = {
            root_dir = root .. "/",
        },
    }, starts[1].config),
    "Tinymist should reuse clients with equivalent normalized roots"
)
assert(
    not starts[1].opts.reuse_client({
        name = "tinymist",
        config = {
            root_dir = nil,
        },
    }, starts[1].config),
    "Tinymist should not reuse a rootless client for a rooted project"
)
assert(
    starts[1].opts.reuse_client({
        name = "tinymist",
        config = {
            root_dir = nil,
        },
    }, {
        root_dir = nil,
    }),
    "Tinymist should reuse rootless clients only for rootless configs"
)

starts = {}
typst.reset()
typst.setup({
    root = root,
    integrations = {
        tinymist = {
            lsp = "auto",
            path = "nvim",
        },
    },
})
started, reason = tinymist.ensure(bufnr, { root = root })
assert(
    started and reason == "started",
    "auto mode should start Tinymist from path"
)
assert(
    starts[1].config.cmd[1] == "nvim",
    "Tinymist path should build the LSP command"
)
assert(
    starts[1].config.settings == nil,
    "empty Tinymist settings should be omitted from LSP config"
)
assert(
    starts[1].config.init_options == nil,
    "empty Tinymist init_options should be omitted from LSP config"
)

starts = {}
vim.g.coc_service_initialized = 1
rawset(vim.lsp, "get_clients", function(opts)
    if opts and opts.bufnr == bufnr then
        return {
            {
                id = 88,
                name = "tinymist",
            },
        }
    end
    return {}
end)
typst.reset()
typst.setup({
    root = root,
    integrations = {
        tinymist = {
            lsp = "auto",
            cmd = { "nvim", "--headless" },
        },
    },
})
started, reason = tinymist.ensure(bufnr, { root = root })
assert(
    not started and reason == "coc",
    "auto mode should skip when coc.nvim is active"
)
assert(
    #starts == 0,
    "auto mode should not start Tinymist when coc.nvim is active"
)
assert(
    tinymist.available(bufnr) == false,
    "auto mode should not reuse native Tinymist when coc.nvim is active"
)

vim.g.coc_service_initialized = true
assert(tinymist.coc_active(), "boolean Coc initialized flag should be detected")
vim.g.coc_service_initialized = nil
rawset(vim.fn, "exists", function(name)
    if name == "*CocAction" then
        return 1
    end
    return 0
end)
assert(tinymist.coc_active(), "CocAction function should be detected")
vim.fn.exists = old_exists

rawset(vim.lsp, "get_clients", function()
    return {}
end)
typst.reset()
typst.setup({
    root = root,
    integrations = {
        tinymist = {
            lsp = "start",
            cmd = { "nvim", "--headless" },
        },
    },
})
started, reason = tinymist.ensure(bufnr, { root = root })
assert(
    started and reason == "started",
    "start mode should override coc.nvim detection"
)
assert(#starts == 1, "start mode should call vim.lsp.start")

rawset(vim.lsp, "get_clients", function(opts)
    if opts and opts.bufnr == bufnr then
        return {
            {
                id = 89,
                name = "tinymist",
            },
        }
    end
    return {}
end)
assert(
    tinymist.available(bufnr) == true,
    "start mode should allow native Tinymist even when coc.nvim is active"
)

starts = {}
attached_client = {
    id = 99,
    name = "tinymist",
}
rawset(vim.lsp, "get_clients", function(opts)
    if opts and opts.bufnr == bufnr then
        return { attached_client }
    end
    return {}
end)
typst.reset()
typst.setup({
    root = root,
    integrations = {
        tinymist = {
            lsp = "detect",
            cmd = { "nvim", "--headless" },
        },
    },
})
started, reason = tinymist.ensure(bufnr, { root = root })
assert(
    started and reason == "attached",
    "detect mode should reuse an attached native Tinymist client"
)
assert(#starts == 0, "detect mode should not start Tinymist")

local project = {
    bufs = {
        [bufnr] = true,
    },
    main = vim.api.nvim_buf_get_name(bufnr),
}
local first_client, first_bufnr = tinymist_clients.first_project_client(project)
assert(
    first_client == attached_client and first_bufnr == bufnr,
    "first_project_client should return attached clients by default"
)
first_client = tinymist_clients.first_project_client(project, {
    request = "async",
})
assert(
    first_client == nil,
    "async client selection should require client.request"
)
attached_client.request = function() end
first_client = tinymist_clients.first_project_client(project, {
    request = "async",
})
assert(
    first_client == attached_client,
    "async client selection should accept clients with request()"
)
attached_client.supports_method = function(_, method)
    return method == "workspace/symbol"
end
first_client = tinymist_clients.first_project_client(project, {
    method = "workspace/symbol",
})
assert(
    first_client == attached_client,
    "method client selection should accept supported methods"
)
first_client = tinymist_clients.first_project_client(project, {
    method = "textDocument/hover",
})
assert(
    first_client == nil,
    "method client selection should reject unsupported methods"
)
attached_client = nil
rawset(vim.lsp, "get_clients", function()
    return {}
end)
for _, mode in ipairs({ "detect", "off" }) do
    starts = {}
    typst.reset()
    typst.setup({
        root = root,
        integrations = {
            tinymist = {
                lsp = mode,
                cmd = { "nvim", "--headless" },
            },
        },
    })
    started, reason = tinymist.ensure(bufnr, { root = root })
    assert(
        not started and reason == mode,
        mode .. " mode should not start Tinymist"
    )
    assert(#starts == 0, mode .. " mode should not call vim.lsp.start")
end

restore()
vim.cmd("qa!")
