local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset({ force = true })

local provider_callback = nil
local provider_output = nil

typst.providers.register("export", "epoch-token-export", {
    export = function(_, opts, callback)
        provider_callback = callback
        provider_output = opts.output_path
        return {
            ok = true,
            pending = true,
            provider = "epoch-token-export",
            path = opts.output_path,
        }
    end,
})

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("export-epoch-token-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
typst.project.set_main(main)

local exported = nil
local pending = typst.artifact.export({
    provider = "epoch-token-export",
    format = "svg",
    output_name = "epoch-token-export",
}, function(result)
    exported = result
end)

assert(
    pending and pending.pending == true,
    "epoch-token export provider should return a pending result"
)
assert(
    type(provider_callback) == "function",
    "epoch-token export provider should receive a callback"
)
assert(
    type(provider_output) == "string" and provider_output ~= "",
    "epoch-token export provider should receive a planned output"
)

typst.reset({ force = true })

vim.fn.mkdir(vim.fn.fnamemodify(provider_output, ":h"), "p")
vim.fn.writefile({ "<svg></svg>" }, provider_output)
provider_callback({
    artifacts = {
        {
            format = "svg",
            path = provider_output,
            provider = "epoch-token-export",
        },
    },
})

assert(
    vim.wait(1000, function()
        return exported ~= nil
    end, 10),
    "epoch-token export provider callback did not settle"
)
assert(
    exported.stale == true and exported.reason == "reset",
    "export provider callback after reset should return stale reset result"
)

typst.reset({ force = true })

vim.cmd("qa!")
