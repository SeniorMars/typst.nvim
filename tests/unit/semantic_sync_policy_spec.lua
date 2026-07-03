local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local forbidden_runtime_patterns = {
    "request_sync",
    "buf_request_sync",
}

local violations = {}
for _, file in
    ipairs(vim.fn.globpath(root .. "/lua/typst", "**/*.lua", false, true))
do
    local rel = file:sub(#root + 2)
    for lnum, line in ipairs(vim.fn.readfile(file)) do
        for _, pattern in ipairs(forbidden_runtime_patterns) do
            if line:find(pattern, 1, true) then
                violations[#violations + 1] = ("%s:%d:%s"):format(
                    rel,
                    lnum,
                    vim.trim(line)
                )
            end
        end
    end
end

assert(
    #violations == 0,
    "runtime Typst/LSP semantic requests must stay async; found sync calls:\n"
        .. table.concat(violations, "\n")
)

local interactive_files = {
    "lua/typst/completion/lsp.lua",
    "lua/typst/context.lua",
    "lua/typst/edit/api_transforms.lua",
    "lua/typst/edit/textobjects.lua",
    "lua/typst/api/navigation.lua",
    "lua/typst/index.lua",
    "lua/typst/integrations/semantic.lua",
    "lua/typst/project/semantic.lua",
    "lua/typst/ui/label_rename.lua",
}

local wait_violations = {}
for _, rel in ipairs(interactive_files) do
    local path = root .. "/" .. rel
    assert(vim.fn.filereadable(path) == 1, "missing interactive file: " .. rel)
    for lnum, line in ipairs(vim.fn.readfile(path)) do
        if line:find("vim.wait", 1, true) then
            wait_violations[#wait_violations + 1] = ("%s:%d:%s"):format(
                rel,
                lnum,
                vim.trim(line)
            )
        end
    end
end

assert(
    #wait_violations == 0,
    "interactive Tinymist semantic paths must not block with vim.wait:\n"
        .. table.concat(wait_violations, "\n")
)

local typst = require("typst")
local project_store = require("typst.project.store")
local services = require("typst.project.services")
local tinymist_symbols = require("typst.integrations.tinymist.symbols")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("semantic-request-failure-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local bufnr = vim.api.nvim_get_current_buf()
local project = typst.project.set_main(main)
local live_project = assert(project_store.get(project.key), "live project")

local old_document_symbols = tinymist_symbols.document_symbols
local old_workspace_symbols = tinymist_symbols.workspace_symbols
tinymist_symbols.document_symbols = function()
    error("document symbols startup failed")
end
tinymist_symbols.workspace_symbols = function()
    error("workspace symbols startup failed")
end

typst.index.collect({
    project = project,
    include_tinymist = true,
    tinymist_timeout_ms = 10,
})

local cleared = vim.wait(1000, function()
    local semantic = (services.index(live_project) or {}).semantic or {}
    local document_cache = semantic.document and semantic.document[bufnr] or nil
    local workspace_cache = semantic.workspace or nil
    return document_cache
        and workspace_cache
        and document_cache.pending == false
        and workspace_cache.pending == false
end, 5)

tinymist_symbols.document_symbols = old_document_symbols
tinymist_symbols.workspace_symbols = old_workspace_symbols

assert(cleared, "Tinymist semantic startup failures should clear pending state")

local semantic = services.index(live_project).semantic
assert(
    semantic.document[bufnr].error
        and semantic.document[bufnr].error.reason == "request_failed",
    "document symbol startup failure should be recorded"
)
assert(
    semantic.workspace.error
        and semantic.workspace.error.reason == "request_failed",
    "workspace symbol startup failure should be recorded"
)

vim.cmd("qa!")
