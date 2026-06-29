local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local project_services = require("typst.project.services")
local util = require("typst.core.util")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("context-tinymist-references-output"),
})

local context = require("typst.context")

local workdir = typst_test_cache_path("context-tinymist-references")
vim.fn.mkdir(workdir, "p")
local main = workdir .. "/main.typ"
vim.fn.writefile({
    "#let target-func() = none",
    "#target-func()",
    "// target-func in comment",
}, main)

vim.cmd.edit(main)
vim.bo.filetype = "typst"
local project = typst.project.set_main(main)
project_services.graph(project).files["C:/Users/Charlie/Project/main.typ"] =
    true

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
local external = vim.fn.tempname() .. ".typ"
local windows_reference_path = "c:\\users\\charlie\\project\\main.typ"
local reference_requests = 0
local fake_client = {
    id = 1001,
    name = "tinymist",
    offset_encoding = "utf-16",
}

function fake_client:supports_method(method)
    return method == "textDocument/references"
end

fake_client.request = function(_, method, params, callback, request_bufnr)
    if method == "textDocument/definition" then
        callback(nil, nil)
        return true, 1
    end

    assert(
        method == "textDocument/references",
        "definition occurrence action should request Tinymist references"
    )
    reference_requests = reference_requests + 1
    assert(
        request_bufnr == bufnr,
        "definition reference action should request against the current buffer"
    )
    assert(
        params.context.includeDeclaration == true,
        "definition reference action should include declarations"
    )
    assert(
        params.position.line == 0,
        "definition reference action should use the captured context position"
    )
    callback(nil, {
        {
            uri = vim.uri_from_fname(main),
            range = {
                start = { line = 0, character = 5 },
                ["end"] = { line = 0, character = 16 },
            },
        },
        {
            uri = vim.uri_from_fname(main),
            range = {
                start = { line = 1, character = 1 },
                ["end"] = { line = 1, character = 12 },
            },
        },
        {
            uri = vim.uri_from_fname(windows_reference_path),
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 11 },
            },
        },
        {
            uri = vim.uri_from_fname(external),
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 0, character = 11 },
            },
        },
    })
    return true, reference_requests
end

local old_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(opts)
    if opts and opts.bufnr == bufnr then
        return { fake_client }
    end
    return {}
end

place_on("target-func")
local actions = typst.context.open({ open = false, semantic = false })
local original_loaded_buffer_for_path = util.loaded_buffer_for_path
local loaded_buffer_lookups = {}
util.loaded_buffer_for_path = function(path)
    if path then
        local key = util.path_key(path)
        loaded_buffer_lookups[key] = (loaded_buffer_lookups[key] or 0) + 1
    end
    return original_loaded_buffer_for_path(path)
end
local callback_refs = nil
local refs_ok, pending = pcall(
    context.execute,
    assert(action_by_id(actions, "definition_references")),
    {
        open = false,
        semantic = true,
        callback = function(items)
            callback_refs = items
        end,
    }
)

util.loaded_buffer_for_path = original_loaded_buffer_for_path
vim.lsp.get_clients = old_get_clients
assert(refs_ok, pending)
assert(pending and pending.pending, "definition references should be async")
local refs = callback_refs

assert(
    reference_requests == 1,
    "definition occurrence action should prefer one Tinymist references request"
)
assert(
    (loaded_buffer_lookups[util.path_key(main)] or 0) >= 4,
    "semantic reference display should read equivalent loaded buffers through the path-identity helper"
)
assert(
    #refs == 3,
    "semantic definition references should be filtered to the current project files"
)
assert(
    refs[1].user_data.provider == "tinymist",
    "semantic reference items should report Tinymist provider"
)
assert(
    refs[1].user_data.semantic == true,
    "semantic reference items should be marked semantic"
)
assert(
    refs[1].text:find("#let target%-func", 1, false),
    "first semantic reference should include declaration text"
)
assert(
    refs[2].text:find("#target%-func", 1, false),
    "second semantic reference should include call text"
)
assert(
    refs[3].filename:find("users", 1, true),
    "Windows-equivalent semantic references should survive project filtering"
)

vim.cmd("qa!")
