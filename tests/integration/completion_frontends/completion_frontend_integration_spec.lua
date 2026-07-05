local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

local require_frontends = vim.env.TYPST_NVIM_REQUIRE_FRONTENDS == "1"

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
rawset(vim.lsp, "get_clients", function(opts)
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
                callbacks[#callbacks + 1] = callback
                return #callbacks
            end,
        },
    }
end)

local function maybe_require(module)
    local ok, value = pcall(require, module)
    if require_frontends then
        assert(ok, module .. " should be installed in frontend smoke CI")
    end
    return ok and value or nil
end

local function callback_result(label)
    return nil,
        {
            items = {
                {
                    label = label,
                    insertText = label,
                },
            },
        }
end

local cmp = maybe_require("cmp")
if cmp then
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
    if type(cmp.register_source) == "function" then
        pcall(cmp.register_source, "typst_nvim_frontend_smoke", source)
    end

    local result = nil
    source:complete({
        context = {
            bufnr = bufnr,
            cursor_before_line = "#tinymist",
        },
        offset = #"#tinymist",
    }, function(items)
        result = items
    end)
    assert(result and result.items, "cmp source should return cmp items")

    callbacks[#callbacks](callback_result("tinymist-cmp-smoke"))
    assert(
        vim.wait(1000, function()
            return refreshes == 1
        end, 5),
        "cmp Tinymist result should refresh the active frontend session"
    )
end

require("typst.completion").reset()

local blink = maybe_require("blink.cmp")
if blink then
    local refreshes = 0
    local source = typst.completion.blink_source({
        context = "markup",
        bufnr = bufnr,
        pos = { 0, 1 },
        limit = 20,
        blink_refresh = function()
            refreshes = refreshes + 1
            return true
        end,
    })
    assert(type(source.enabled) == "function", "blink source needs enabled()")
    assert(
        type(source.get_completions) == "function",
        "blink source needs get_completions()"
    )
    assert(type(blink) == "table", "blink.cmp should expose a module table")

    local result = nil
    source:get_completions({
        context = {
            bufnr = bufnr,
            cursor_before_line = "#tinymist",
        },
        offset = #"#tinymist",
    }, function(items)
        result = items
    end)
    assert(result and result.items, "blink source should return blink items")

    callbacks[#callbacks](callback_result("tinymist-blink-smoke"))
    assert(
        vim.wait(1000, function()
            return refreshes == 1
        end, 5),
        "blink Tinymist result should refresh the active frontend session"
    )
end

vim.lsp.get_clients = original_get_clients
vim.cmd("qa!")
