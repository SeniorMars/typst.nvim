local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("coordinate-unicode-output"),
    diagnostics = {
        enabled = true,
        use_quickfix = true,
    },
})

local workdir = typst_test_cache_path("coordinate-unicode")
vim.fn.mkdir(workdir, "p")
local main = workdir .. "/main.typ"
local line = "é α 中 😀 é\t<unicode:label> @unicode:label"
vim.fn.writefile({ line }, main)

vim.cmd.edit(main)
vim.bo.filetype = "typst"
local bufnr = vim.api.nvim_get_current_buf()
local project = typst.project.set_main(main)

local label_byte_col = line:find("<unicode:label>", 1, true) - 1
local ref_byte_col = line:find("@unicode:label", 1, true) - 1
local ref_utf16 = vim.str_utfindex(line, "utf-16", ref_byte_col)

local diagnostics = require("typst.diagnostics")
diagnostics.publish(
    project,
    ("%s:1:%d: error: unicode column"):format(main, ref_byte_col + 1)
)
local published = vim.diagnostic.get(bufnr, {
    namespace = diagnostics.namespace_for(project),
})
assert(#published == 1, "Unicode diagnostic should be published")
assert(
    published[1].lnum == 0 and published[1].col == ref_byte_col,
    "diagnostic parser should keep internal UTF-8 byte columns"
)

local quickfix = vim.fn.getqflist()
assert(#quickfix == 1, "Unicode diagnostic should populate quickfix")
assert(
    quickfix[1].lnum == 1 and quickfix[1].col == ref_byte_col + 1,
    "quickfix should expose one-based byte columns"
)

local fake_client = {
    id = 4242,
    name = "tinymist",
    offset_encoding = "utf-16",
}

function fake_client:supports_method(method)
    return method == "textDocument/rename"
        or method == "textDocument/references"
end

local requested = {}
fake_client.request = function(_, method, params, callback, request_bufnr)
    assert(request_bufnr == bufnr, "Tinymist request should use source buffer")
    requested[method] = params
    if method == "textDocument/rename" then
        callback(nil, { changes = {} })
    elseif method == "textDocument/references" then
        callback(nil, {
            {
                uri = vim.uri_from_fname(main),
                range = {
                    start = { line = 0, character = ref_utf16 },
                    ["end"] = { line = 0, character = ref_utf16 + 13 },
                },
            },
        })
    else
        error("unexpected Tinymist method: " .. tostring(method))
    end
    return true, 1
end

local requests = require("typst.integrations.tinymist.requests")
local rename_result = nil
requests.rename(bufnr, "renamed:label", {
    client = fake_client,
    pos = { 0, ref_byte_col },
    apply = false,
    callback = function(result)
        rename_result = result
    end,
})
assert(
    vim.wait(1000, function()
        return rename_result ~= nil
    end, 10),
    "Tinymist rename callback did not run"
)
assert(rename_result.ok, "Tinymist rename should complete")
assert(
    requested["textDocument/rename"].position.character == ref_utf16,
    "Tinymist rename should convert byte column to UTF-16"
)

local references_result = nil
requests.references(bufnr, {
    client = fake_client,
    pos = { 0, ref_byte_col },
    callback = function(result)
        references_result = result
    end,
})
assert(
    vim.wait(1000, function()
        return references_result ~= nil
    end, 10),
    "Tinymist references callback did not run"
)
assert(references_result.ok, "Tinymist references should complete")
assert(
    requested["textDocument/references"].position.character == ref_utf16,
    "Tinymist references should convert request byte column to UTF-16"
)
assert(
    references_result.references[1].col == ref_byte_col + 1,
    "Tinymist references should normalize UTF-16 locations to byte columns"
)

local plan = require("typst.ui.label_rename").plan(
    bufnr,
    { name = "unicode:label" },
    "renamed:label"
)
local saw_label = false
local saw_reference = false
for _, edit in ipairs(plan.edits or {}) do
    if edit.kind == "label" and edit.expected == "<unicode:label>" then
        saw_label = edit.start_col == label_byte_col
            and edit.end_col == label_byte_col + #"<unicode:label>"
    elseif edit.kind == "reference" and edit.expected == "@unicode:label" then
        saw_reference = edit.start_col == ref_byte_col
            and edit.end_col == ref_byte_col + #"@unicode:label"
    end
end
assert(
    saw_label and saw_reference,
    "label rename planning should preserve Unicode byte ranges"
)

vim.cmd("qa!")
