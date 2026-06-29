local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    completion = {
        include_packages = false,
        include_templates = false,
        include_fonts = false,
    },
})

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "#tinymist" })

local original_get_clients = vim.lsp.get_clients
local callbacks = {}
vim.lsp.get_clients = function(opts)
    if not opts or opts.bufnr ~= bufnr then
        return {}
    end
    return {
        {
            name = "tinymist",
            offset_encoding = "utf-16",
            supports_method = function()
                return true
            end,
            request = function(_, _, _, callback)
                callbacks[#callbacks + 1] = function(label)
                    if label == false then
                        callback("completion failed", nil)
                        return
                    end
                    callback(nil, {
                        items = {
                            {
                                label = label,
                                insertText = label,
                            },
                        },
                    })
                end
                return #callbacks
            end,
        },
    }
end

local refreshes = {}
local source = typst.completion.cmp_source({
    context = "markup",
    bufnr = bufnr,
    pos = { 0, 1 },
    limit = 20,
    cmp_refresh = function(_, refresh_opts)
        refreshes[#refreshes + 1] = {
            refresh = true,
            opts = refresh_opts,
        }
    end,
})

source:complete({
    context = {
        bufnr = bufnr,
        cursor_before_line = "#tinymist",
    },
    offset = #"#tinymist",
}, function(result)
    refreshes[#refreshes + 1] = result
end)

source:complete({
    context = {
        bufnr = bufnr,
        cursor_before_line = "#tinymist",
    },
    offset = #"#tinymist",
}, function(result)
    refreshes[#refreshes + 1] = result
end)

assert(#refreshes == 2, "cmp source should respond immediately twice")
callbacks[1]("tinymist-fresh")
assert(
    vim.wait(1000, function()
        return #refreshes == 3
    end, 5),
    "fresh cmp Tinymist callback should request a frontend refresh"
)
assert(
    refreshes[3].refresh == true,
    "fresh cmp Tinymist callback should not reuse the original callback"
)

source:complete({
    context = {
        bufnr = bufnr,
        cursor_before_line = "#tinymist",
    },
    offset = #"#tinymist",
}, function(result)
    refreshes[#refreshes + 1] = result
end)

assert(
    vim.tbl_filter(function(item)
        return item.word == "tinymist-fresh"
    end, refreshes[4].items)[1],
    "refreshed cmp request should include current Tinymist item"
)

require("typst.completion").reset()
typst.completion.complete({
    base = "tinymist",
    context = "markup",
    bufnr = bufnr,
    pos = { 0, 1 },
    limit = 20,
})
callbacks[#callbacks](false)
vim.wait(20, function()
    return false
end, 1, false)

typst.completion.complete({
    base = "tinymist",
    context = "markup",
    bufnr = bufnr,
    pos = { 0, 1 },
    limit = 20,
})
callbacks[#callbacks]("tinymist-stable")
assert(
    vim.wait(1000, function()
        local items = typst.completion.complete({
            base = "tinymist",
            context = "markup",
            bufnr = bufnr,
            pos = { 0, 1 },
            limit = 20,
        })
        return vim.tbl_filter(function(item)
            return item.word == "tinymist-stable"
        end, items)[1] ~= nil
    end, 5),
    "replacement Tinymist completion should be cached"
)

for i = 1, 63 do
    typst.completion.complete({
        base = "tinymist",
        context = "markup",
        bufnr = bufnr,
        pos = { 0, i + 10 },
        limit = 20,
    })
    callbacks[#callbacks]("tinymist-extra-" .. i)
    vim.wait(20, function()
        return false
    end, 1, false)
end

local cached_after_eviction = typst.completion.complete({
    base = "tinymist",
    context = "markup",
    bufnr = bufnr,
    pos = { 0, 1 },
    limit = 20,
})
assert(
    vim.tbl_filter(function(item)
        return item.word == "tinymist-stable"
    end, cached_after_eviction)[1],
    "stale failed cache keys should not evict a fresh replacement entry"
)

vim.lsp.get_clients = original_get_clients
vim.cmd("qa!")
