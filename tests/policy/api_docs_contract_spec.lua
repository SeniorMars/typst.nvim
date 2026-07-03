local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("api-docs-contract-output"),
})

local function read_doc(path)
    return table.concat(vim.fn.readfile(root .. "/" .. path), "\n")
end

local api_doc = read_doc("API.md")
local help_doc = read_doc("doc/typst.txt")
local readme_doc = read_doc("README.md")
local provider_contracts_doc = read_doc("docs/provider-contracts.md")

local function sorted_keys(set)
    local out = {}
    for key in pairs(set or {}) do
        out[#out + 1] = key
    end
    table.sort(out)
    return out
end

local function exact_doc_list(content, name)
    local start_marker = ("<!-- typst.nvim %s:start -->"):format(name)
    local end_marker = ("<!-- typst.nvim %s:end -->"):format(name)
    local start_pos = content:find(start_marker, 1, true)
    assert(start_pos, "API.md missing marker: " .. start_marker)

    local end_pos = content:find(end_marker, start_pos, true)
    assert(end_pos, "API.md missing marker: " .. end_marker)

    local block = content:sub(start_pos + #start_marker, end_pos - 1)
    local values = {}
    for symbol in block:gmatch("%- `([^`]+)`") do
        values[#values + 1] = symbol
    end

    assert(#values > 0, "API.md marker block is empty: " .. name)
    return values
end

local function assert_same_list(label, actual, expected)
    assert(
        #actual == #expected,
        ("%s count mismatch: docs=%d runtime=%d"):format(
            label,
            #actual,
            #expected
        )
    )
    for index, value in ipairs(expected) do
        assert(
            actual[index] == value,
            ("%s mismatch at #%d: docs=%s runtime=%s"):format(
                label,
                index,
                tostring(actual[index]),
                value
            )
        )
    end
end

assert_same_list(
    "stable_symbols",
    exact_doc_list(api_doc, "stable-symbols"),
    typst.stable_symbols()
)
assert_same_list(
    "experimental_symbols",
    exact_doc_list(api_doc, "experimental-symbols"),
    typst.experimental_symbols()
)

local public_symbols = {}
for _, symbol in ipairs(typst.public_symbols()) do
    public_symbols[symbol] = true
end

for label, target in readme_doc:gmatch("%[([^%]]+)%]%(([^%)]+)%)") do
    if
        not target:match("^%a[%w+.-]*:")
        and not target:match("^#")
        and target:match("%.md$")
    then
        local normalized = target:gsub("#.*$", "")
        assert(
            vim.fn.filereadable(root .. "/" .. normalized) == 1,
            ("README.md link %q points to missing file: %s"):format(
                label,
                target
            )
        )
    end
end

for _, doc in ipairs({
    { path = "README.md", content = readme_doc },
    { path = "doc/typst.txt", content = help_doc },
    { path = "docs/provider-contracts.md", content = provider_contracts_doc },
}) do
    assert(
        not doc.content:find("integrations.tinymist.provider", 1, true),
        doc.path
            .. " should document integrations.tinymist.lsp, not a nonexistent provider key"
    )
end

for _, doc in ipairs({
    { path = "README.md", content = readme_doc },
    { path = "doc/typst.txt", content = help_doc },
}) do
    for _, internal_require in ipairs({
        'require("typst.project.store")',
        "require('typst.project.store')",
        'require("typst.project.registry")',
        "require('typst.project.registry')",
    }) do
        assert(
            not doc.content:find(internal_require, 1, true),
            doc.path
                .. " must not recommend live project internals: "
                .. internal_require
        )
    end
end

local function documented_api_examples(content)
    local examples = {}
    for symbol in content:gmatch('require%(%"typst%"%)%.([%w_%.]+)%s*%(') do
        examples[symbol] = true
    end
    return sorted_keys(examples)
end

for _, doc in ipairs({
    { path = "API.md", content = api_doc },
    { path = "doc/typst.txt", content = help_doc },
}) do
    for _, symbol in ipairs(documented_api_examples(doc.content)) do
        assert(
            public_symbols[symbol],
            ("%s documents missing public API symbol: %s"):format(
                doc.path,
                symbol
            )
        )
    end
end

local function registered_typst_commands()
    local commands = {}
    for name in pairs(vim.api.nvim_get_commands({ builtin = false })) do
        if name:match("^Typst") then
            commands[#commands + 1] = name
        end
    end
    table.sort(commands)
    return commands
end

local function command_refs(content)
    local refs = {}
    for name in content:gmatch(":(Typst[%w]+)") do
        refs[name] = true
    end
    for name in content:gmatch("%*:(Typst[%w]+)%*") do
        refs[name] = true
    end
    return refs
end

local api_commands_section = api_doc:match("\n## Commands\n(.-)\n## Events\n")
assert(api_commands_section, "API.md missing Commands section")

local command_docs = {
    {
        path = "API.md Commands section",
        refs = command_refs(api_commands_section),
        exact = true,
    },
    { path = "doc/typst.txt", refs = command_refs(help_doc) },
}

local registered_commands = registered_typst_commands()
local registered_command_set = {}
for _, command in ipairs(registered_commands) do
    registered_command_set[command] = true
    for _, doc in ipairs(command_docs) do
        assert(
            doc.refs[command],
            ("%s missing registered command: :%s"):format(doc.path, command)
        )
    end
end

for _, doc in ipairs(command_docs) do
    if doc.exact then
        for command in pairs(doc.refs) do
            assert(
                registered_command_set[command],
                ("%s documents unregistered command: :%s"):format(
                    doc.path,
                    command
                )
            )
        end
    end
end

local public_events = {}
for _, event in ipairs(typst.contract().events or {}) do
    public_events[event] = true
end

assert(
    public_events.TypstEventProjectAttach,
    "event alias source should expose project attach event"
)
assert(
    public_events.TypstEventCompileSuccess,
    "event alias source should expose compile success event"
)
assert(
    public_events.TypstEventPreviewStopped,
    "event alias source should expose preview stopped event"
)

for _, doc in ipairs({
    { path = "API.md", content = api_doc },
    { path = "doc/typst.txt", content = help_doc },
}) do
    for _, event in ipairs(sorted_keys(public_events)) do
        assert(
            doc.content:find("- `" .. event .. "`", 1, true),
            ("%s missing public event: %s"):format(doc.path, event)
        )
    end
end

vim.cmd("qa!")
