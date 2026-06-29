local contract = require("tests.helpers.api_contract")
local root, typst = contract.setup()

local public_functions = {
    "setup",
    "api_version",
    "version",
    "public_symbols",
    "stable_symbols",
    "experimental_symbols",
    "is_setup",
    "reset",
}

for _, name in ipairs(public_functions) do
    assert(
        type(typst[name]) == "function",
        ("missing public Lua function: %s"):format(name)
    )
end

assert(
    typst.api_version() == 1,
    "public API version should be stable and explicit"
)
local version = typst.version()
assert(
    type(version) == "table" and version.api == 1,
    "version() should report the public API level"
)
for _, name in ipairs({
    "compile",
    "set_main",
    "register_provider",
    "unwrap_function",
}) do
    assert(
        typst[name] == nil,
        ("removed flat API should stay absent: %s"):format(name)
    )
end
assert(
    type(typst.invalidation) == "table",
    "missing public Lua namespace: invalidation"
)
assert(
    type(typst.invalidation.subscribe) == "function",
    "invalidation namespace should expose subscribe"
)
assert(
    type(typst.project.on_invalidate) == "function",
    "project namespace should expose invalidation subscriptions"
)
assert(
    type(typst.project.services) == "function",
    "project namespace should expose service snapshots"
)
assert(
    type(typst.project.operations) == "function",
    "project namespace should expose operation service snapshots"
)
assert(
    typst.debug == nil,
    "debug helpers should not widen the stable public API"
)
local stable_symbols = typst.stable_symbols()
local experimental_symbols = typst.experimental_symbols()
assert(
    vim.tbl_contains(stable_symbols, "project.attach"),
    "stable API should explicitly include project.attach"
)
assert(
    vim.tbl_contains(stable_symbols, "compiler.compile"),
    "stable API should explicitly include compiler.compile"
)
assert(
    vim.tbl_contains(stable_symbols, "completion.complete"),
    "stable API should explicitly include completion.complete"
)
assert(
    not vim.tbl_contains(stable_symbols, "project.services"),
    "runtime project helpers should not become stable by namespace introspection"
)
assert(
    not vim.tbl_contains(stable_symbols, "project.operations"),
    "runtime project operation helpers should not become stable by namespace introspection"
)
assert(
    not vim.tbl_contains(stable_symbols, "development.profile"),
    "development workflows should not be part of the stable pre-1.0 API"
)
assert(
    vim.tbl_contains(experimental_symbols, "development.profile"),
    "broad pre-1.0 namespaces should be reported as experimental"
)
assert(
    vim.tbl_contains(experimental_symbols, "project.services"),
    "runtime project helpers should be reported as experimental"
)
assert(
    vim.tbl_contains(experimental_symbols, "project.operations"),
    "runtime project operation helpers should be reported as experimental"
)
assert(
    type(require("typst.internal.debug").telemetry().setup) == "table",
    "setup should record performance telemetry"
)

local function assert_namespace(namespace, names)
    assert(type(namespace) == "table", "missing public Lua namespace")
    for _, name in ipairs(names) do
        assert(
            type(namespace[name]) == "function",
            ("missing public Lua namespace function: %s"):format(name)
        )
    end
end

assert_namespace(typst.project, {
    "attach",
    "detach",
    "get",
    "snapshot",
    "projects",
    "set_main",
    "toggle_main",
    "edit_main",
    "cd",
    "reload_state",
    "clear_cache",
})

assert_namespace(typst.compiler, {
    "compile",
    "compile_selected",
    "output",
    "watch",
    "stop",
    "stop_all",
    "status",
    "current_output",
})

assert_namespace(typst.viewer, {
    "view",
    "view_forward",
    "view_inverse",
    "capabilities",
    "preview_capabilities",
    "clean",
    "clean_preview",
    "preview",
    "preview_open_browser",
    "preview_reload",
    "preview_status",
    "preview_stop",
    "preview_toggle",
    "preview_inverse",
})

assert_namespace(typst.navigation, {
    "files",
    "toc",
    "toc_open",
    "toc_refresh",
    "toc_toggle",
    "labels",
    "citations",
    "symbols",
    "follow",
    "hover",
    "pick",
    "pick_items",
})

assert_namespace(typst.diagnostics, {
    "quickfix",
    "errors",
    "bibliography",
})

assert_namespace(typst.ui, {
    "info",
    "status",
    "status_report",
    "status_all",
    "statusline",
    "count",
    "log",
})

assert_namespace(typst.tools, {
    "format",
    "lint",
    "grammar",
    "font_diagnostics",
})

for _, name in ipairs({
    "doc",
    "docs",
    "doc_symbol",
    "doc_search",
    "doc_package",
    "doc_source",
    "doc_online",
}) do
    assert(
        typst[name] == nil,
        ("removed TypstDoc API should stay absent: %s"):format(name)
    )
end

local public_conceal_functions = {
    "enable",
    "disable",
    "toggle",
    "refresh",
    "inspect",
    "is_enabled",
    "register",
    "unregister",
    "custom",
}

assert(type(typst.conceal) == "table", "missing public Lua namespace: conceal")
for _, name in ipairs(public_conceal_functions) do
    assert(
        type(typst.conceal[name]) == "function",
        ("missing public Lua function: conceal.%s"):format(name)
    )
end

local public_index_functions = {
    "collect",
    "headings",
    "labels",
    "citations",
    "imports",
    "todos",
    "definitions",
    "glossary_entries",
    "paths",
    "reset",
    "mark_dirty",
}

assert(type(typst.index) == "table", "missing public Lua namespace: index")
for _, name in ipairs(public_index_functions) do
    assert(
        type(typst.index[name]) == "function",
        ("missing public Lua function: index.%s"):format(name)
    )
end

local public_syntax_functions = {
    "package_extensions",
    "package_matches",
    "refresh",
    "clear",
    "namespace",
}

assert(type(typst.syntax) == "table", "missing public Lua namespace: syntax")
for _, name in ipairs(public_syntax_functions) do
    assert(
        type(typst.syntax[name]) == "function",
        ("missing public Lua function: syntax.%s"):format(name)
    )
end

local public_picker_functions = {
    "items",
    "open",
    "pick",
    "open_item",
}

assert(type(typst.picker) == "table", "missing public Lua namespace: picker")
for _, name in ipairs(public_picker_functions) do
    assert(
        type(typst.picker[name]) == "function",
        ("missing public Lua function: picker.%s"):format(name)
    )
end

local public_package_functions = {
    "info",
    "open",
    "readme",
    "source",
    "lookup",
    "cached_packages",
    "prewarm",
}

assert(type(typst.package) == "table", "missing public Lua namespace: package")
for _, name in ipairs(public_package_functions) do
    assert(
        type(typst.package[name]) == "function",
        ("missing public Lua function: package.%s"):format(name)
    )
end

local public_symbol_functions = {
    "info",
    "variants",
    "search",
    "lookup",
}

assert(type(typst.symbol) == "table", "missing public Lua namespace: symbol")
for _, name in ipairs(public_symbol_functions) do
    assert(
        type(typst.symbol[name]) == "function",
        ("missing public Lua function: symbol.%s"):format(name)
    )
end

local public_imaps_functions = {
    "register",
    "unregister",
    "active",
    "list",
    "lines",
}

assert(type(typst.imaps) == "table", "missing public Lua namespace: imaps")
for _, name in ipairs(public_imaps_functions) do
    assert(
        type(typst.imaps[name]) == "function",
        ("missing public Lua function: imaps.%s"):format(name)
    )
end

local public_completion_functions = {
    "complete",
    "native",
    "cmp",
    "blink",
    "cmp_source",
    "blink_source",
    "omnifunc",
    "signature",
}

assert(
    type(typst.completion) == "table",
    "missing public Lua namespace: completion"
)
for _, name in ipairs(public_completion_functions) do
    assert(
        type(typst.completion[name]) == "function",
        ("missing public Lua function: completion.%s"):format(name)
    )
end

local public_bibliography_functions = {
    "diagnostics",
    "clear_diagnostics",
    "diagnostics_namespace",
    "foldexpr",
    "indentexpr",
    "fields",
    "expanded_fields",
    "search",
    "insert_text",
    "insert",
    "open",
    "preview",
    "attachment",
    "attachments",
    "rename_plan",
    "rename_key",
    "status",
    "parse_bibtex_file",
    "parse_hayagriva_file",
}

assert(
    type(typst.bibliography) == "table",
    "missing public Lua namespace: bibliography"
)
for _, name in ipairs(public_bibliography_functions) do
    assert(
        type(typst.bibliography[name]) == "function",
        ("missing public Lua function: bibliography.%s"):format(name)
    )
end

local public_artifact_functions = {
    "export",
    "html_preview",
    "presentation",
    "list",
    "open",
    "clean",
}

assert(
    type(typst.artifact) == "table",
    "missing public Lua namespace: artifact"
)
for _, name in ipairs(public_artifact_functions) do
    assert(
        type(typst.artifact[name]) == "function",
        ("missing public Lua function: artifact.%s"):format(name)
    )
end

local public_evaluation_functions = {
    "eval",
    "selection",
    "inspect",
}

assert(
    type(typst.evaluation) == "table",
    "missing public Lua namespace: evaluation"
)
for _, name in ipairs(public_evaluation_functions) do
    assert(
        type(typst.evaluation[name]) == "function",
        ("missing public Lua function: evaluation.%s"):format(name)
    )
end

local public_template_functions = {
    "init",
    "list",
}

assert(
    type(typst.template) == "table",
    "missing public Lua namespace: template"
)
for _, name in ipairs(public_template_functions) do
    assert(
        type(typst.template[name]) == "function",
        ("missing public Lua function: template.%s"):format(name)
    )
end

local public_development_functions = {
    "profile",
    "test",
    "bench",
    "coverage",
}

assert(
    type(typst.development) == "table",
    "missing public Lua namespace: development"
)
for _, name in ipairs(public_development_functions) do
    assert(
        type(typst.development[name]) == "function",
        ("missing public Lua function: development.%s"):format(name)
    )
end

local public_semantic_functions = {
    "inlay_hints_toggle",
    "color_info",
    "document_links",
    "code_lens",
    "workspace_symbols",
    "references",
    "rename_preview",
    "selection_expand",
}

assert(
    type(typst.semantic) == "table",
    "missing public Lua namespace: semantic"
)
for _, name in ipairs(public_semantic_functions) do
    assert(
        type(typst.semantic[name]) == "function",
        ("missing public Lua function: semantic.%s"):format(name)
    )
end

local public_render_functions = {
    "fragment",
    "equation",
    "image",
    "page",
    "cache_clear",
    "cache_entries",
}

assert(type(typst.render) == "table", "missing public Lua namespace: render")
for _, name in ipairs(public_render_functions) do
    assert(
        type(typst.render[name]) == "function",
        ("missing public Lua function: render.%s"):format(name)
    )
end

local public_match_highlight_functions = {
    "enable",
    "disable",
    "toggle",
    "refresh",
    "is_enabled",
}

assert(
    type(typst.match_highlight) == "table",
    "missing public Lua namespace: match_highlight"
)
for _, name in ipairs(public_match_highlight_functions) do
    assert(
        type(typst.match_highlight[name]) == "function",
        ("missing public Lua function: match_highlight.%s"):format(name)
    )
end

local public_metadata_functions = {
    "available_versions",
    "catalog",
    "stdlib",
    "stdlib_item",
    "stdlib_complete",
    "stdlib_param_docs",
    "stdlib_constants_by_type",
    "signature",
    "shorthands",
    "symbol",
    "symbol_glyph",
    "symbol_variants",
    "symbol_deprecation",
    "symbol_names",
    "emoji",
    "emoji_glyph",
    "emoji_variants",
    "emoji_names",
    "emojis",
}

assert(
    type(typst.metadata) == "table",
    "missing public Lua namespace: metadata"
)
for _, name in ipairs(public_metadata_functions) do
    assert(
        type(typst.metadata[name]) == "function",
        ("missing public Lua function: metadata.%s"):format(name)
    )
end

local public_provider_functions = {
    "register",
    "unregister",
    "get",
    "has",
    "names",
}

assert(
    type(typst.providers) == "table",
    "missing public Lua namespace: providers"
)
for _, name in ipairs(public_provider_functions) do
    assert(
        type(typst.providers[name]) == "function",
        ("missing public Lua function: providers.%s"):format(name)
    )
end

local removed = {
    "compile",
    "set_main",
    "package_info",
    "symbol_info",
    "complete",
    "register_provider",
    "unwrap_function",
    "render_page",
}

for _, name in ipairs(removed) do
    assert(
        typst[name] == nil,
        ("removed flat API alias should stay unavailable: %s"):format(name)
    )
end

assert(
    type(typst.compiler.compile) == "function",
    "namespaced compiler API should remain available"
)
assert(
    type(typst.project.set_main) == "function",
    "namespaced project API should remain available"
)
assert(
    type(typst.bibliography.diagnostics_namespace(0)) == "number",
    "bibliography namespace helper should accept numeric buffer handles"
)

for _, name in ipairs(typst.stable_symbols()) do
    assert(
        not vim.tbl_contains(removed, name),
        ("stable symbol list should omit removed flat alias %s"):format(name)
    )
end

vim.cmd("qa!")
