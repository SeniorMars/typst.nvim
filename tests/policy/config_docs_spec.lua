local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local docs = require("typst.config.docs")
local config_spec = require("typst.config.spec")

assert(
    config_spec.optional_paths["preview.open"] == true,
    "config spec should own setup-time optional paths"
)
assert(
    vim.tbl_contains(config_spec.doc_nil_defaults, "preview.open"),
    "config spec should own generated-doc nil defaults"
)
assert(
    config_spec.doc_optional_types["preview.open"] == "nil|function",
    "config spec should own generated-doc optional types"
)

local function read(path)
    return table.concat(vim.fn.readfile(root .. "/" .. path), "\n")
end

local function assert_equal(path, actual, expected)
    actual = actual:gsub("\n+$", "")
    expected = expected:gsub("\n+$", "")
    assert(
        actual == expected,
        ("%s is stale; run `just config-docs`"):format(path)
    )
end

local markdown = docs.markdown()
local schema_json = docs.schema_json()
local schema = docs.schema()
local seen = {}

assert(#schema > 100, "generated config schema should cover runtime defaults")
for index, item in ipairs(schema) do
    assert(type(item.path) == "string" and item.path ~= "", "bad schema path")
    assert(type(item.type) == "string" and item.type ~= "", "bad schema type")
    assert(
        type(item.default) == "string",
        "schema default should be a display string"
    )
    assert(not seen[item.path], "duplicate config schema path: " .. item.path)
    seen[item.path] = true
    if index > 1 then
        assert(
            schema[index - 1].path < item.path,
            "config schema should be sorted"
        )
    end
end

for _, required in ipairs({
    "completion.package_cache_ttl_ms",
    "completion.package_cache_prewarm",
    "diagnostics.external_paths",
    "diagnostics.font_scan_timeout_ms",
    "diagnostics.max_external_buffers",
    "diagnostics.overflow",
    "format.timeout_ms",
    "preview.browser.export.mode",
    "preview.browser.refresh_ms",
    "preview.browser.style.variables",
    "preview.cache.max_entries",
    "preview.export.mode",
    "preview.provider",
    "project.import_scan_max_descendant_depth",
    "project.index.fs_watchers",
    "project.index.max_depth",
    "project.index.max_entries",
    "project.index.max_files",
    "render.cache.ttl_ms",
}) do
    assert(seen[required], "missing generated config key: " .. required)
end

assert_equal(
    "docs/config-reference.md",
    read("docs/config-reference.md"),
    markdown
)
assert_equal(
    "data/config-schema.json",
    read("data/config-schema.json"),
    schema_json
)

vim.cmd("qa!")
