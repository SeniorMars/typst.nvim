local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("context-tinymist-rename-output"),
})

local context = require("typst.context")

local workdir = typst_test_cache_path("context-tinymist-rename")
vim.fn.mkdir(workdir, "p")
local main = workdir .. "/main.typ"
vim.fn.writefile({
    "= Scratch <old:label>",
    "See @old:label.",
}, main)

vim.cmd.edit(main)
vim.bo.filetype = "typst"
typst.project.set_main(main)

local function action_by_id(actions, id)
    for _, action in ipairs(actions) do
        if action.id == id then
            return action
        end
    end
end

local function place_on(needle)
    local bufnr = vim.api.nvim_get_current_buf()
    for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        local start_col = line:find(needle, 1, true)
        if start_col then
            vim.api.nvim_win_set_cursor(0, { row, start_col - 1 })
            return
        end
    end
    error("fixture missing text: " .. needle)
end

local bufnr = vim.api.nvim_get_current_buf()
local requested
local fake_client = {
    id = 999,
    name = "tinymist",
    offset_encoding = "utf-16",
}

function fake_client:supports_method(method)
    return method == "textDocument/rename"
end

fake_client.request = function(_, method, params, callback, request_bufnr)
    assert(
        method == "textDocument/rename",
        "context label rename should request LSP rename"
    )
    assert(
        request_bufnr == bufnr,
        "context label rename should request against current buffer"
    )
    assert(
        params.newName == "new:label",
        "context label rename should pass requested label name"
    )
    requested = params
    callback(nil, {
        changes = {
            [vim.uri_from_bufnr(bufnr)] = {
                {
                    range = {
                        start = { line = 0, character = 11 },
                        ["end"] = { line = 0, character = 20 },
                    },
                    newText = "new:label",
                },
            },
        },
    })
    return true, 1
end

local old_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(opts)
    if opts and opts.bufnr == bufnr then
        return { fake_client }
    end
    return {}
end

place_on("old:label")
local actions = typst.context.open({ open = false })
local callback_result = nil
local result = context.execute(assert(action_by_id(actions, "label_rename")), {
    open = false,
    new_name = "new:label",
    callback = function(callback_value)
        callback_result = callback_value
    end,
})

vim.lsp.get_clients = old_get_clients

assert(result and result.pending, "label rename should use async Tinymist")
result = callback_result
assert(result and result.ok, "label rename should report semantic success")
assert(
    result.provider == "tinymist",
    "label rename should prefer Tinymist rename"
)
assert(
    result.applied == true,
    "semantic rename should apply the workspace edit by default"
)
assert(
    requested and requested.position,
    "semantic rename should include cursor position"
)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(
    lines[1]:find("<new:label>", 1, true),
    "Tinymist edit should update the label definition"
)
assert(
    lines[2]:find("@old:label", 1, true),
    "successful Tinymist rename should not run syntactic fallback"
)

vim.cmd("qa!")
