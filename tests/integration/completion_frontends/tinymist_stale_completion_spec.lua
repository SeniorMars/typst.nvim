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
            supports_method = function(_, method)
                return method == "textDocument/completion"
            end,
            request = function(_, _, _, callback)
                callbacks[#callbacks + 1] = function(label)
                    callback(nil, {
                        items = {
                            {
                                label = label,
                                insertText = label,
                            },
                        },
                    })
                end
                return true, #callbacks
            end,
        },
    }
end

local ok, err = xpcall(function()
    local refreshes = 0
    local source = typst.completion.cmp_source({
        context = "markup",
        bufnr = bufnr,
        pos = { 0, 1 },
        limit = 20,
        cmp_refresh = function()
            refreshes = refreshes + 1
            return true
        end,
    })

    local initial = nil
    source:complete({
        context = {
            bufnr = bufnr,
            cursor_before_line = "#tinymist",
        },
        offset = #"#tinymist",
    }, function(result)
        initial = result
    end)
    assert(initial and initial.items, "cmp source should return immediately")
    assert(#callbacks == 1, "fake Tinymist should receive one request")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "#tinymist changed before response",
    })
    callbacks[1]("tinymist-stale")
    vim.wait(50, function()
        return false
    end, 1, false)
    assert(refreshes == 0, "stale Tinymist completion should not refresh cmp")

    local after_edit = typst.completion.cmp({
        base = "tinymist",
        context = "markup",
        bufnr = bufnr,
        pos = { 0, 1 },
        limit = 20,
    })
    for _, item in ipairs(after_edit) do
        assert(
            item.word ~= "tinymist-stale",
            "stale Tinymist completion should not be cached"
        )
    end
    assert(
        #callbacks == 2,
        "fresh buffer tick should start a replacement Tinymist request"
    )
end, debug.traceback)

require("typst.completion").reset()
vim.lsp.get_clients = original_get_clients

if not ok then
    error(err)
end

vim.cmd("qa!")
