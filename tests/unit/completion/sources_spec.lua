local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local index = require("typst.index")
local metadata = require("typst.metadata")
local registry_scan = require("typst.package.registry_scan")
local typst = require("typst")
local buffer_context = require("typst.core.buffer_context")
local completion_items = require("typst.completion.items")
local completion_match = require("typst.completion.match")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("completion-output"),
    completion = {
        universe_index_paths = { root .. "/tests/fixtures/universe-index.json" },
        csl_styles = { "custom-config-style" },
        raw_languages = { "custom-raw-lang" },
        color_names = { "brand-primary" },
        font_families = { "Unit Test Serif" },
        font_scan_timeout_ms = 0,
    },
})

local old_package_cache_path = vim.env.TYPST_PACKAGE_CACHE_PATH
vim.env.TYPST_PACKAGE_CACHE_PATH = root .. "/tests/fixtures/packages"
require("typst.completion.packages").prewarm({
    force = true,
    schedule = false,
})

local function find_item(items, word)
    for _, item in ipairs(items) do
        if item.word == word then
            return item
        end
    end
end

local function assert_item(items, word, message)
    local item = find_item(items, word)
    assert(item, message)
    return item
end

local original_root_signatures = registry_scan.root_signatures
local original_scan_roots = registry_scan.scan_roots

assert(
    completion_match.prefix("Table.Cell", "table."),
    "completion prefix matching should be case-insensitive"
)
assert(
    not completion_match.prefix("table.cell", "figure."),
    "completion prefix matching should reject unrelated prefixes"
)
local helper_items = {}
local helper_seen = {}
assert(
    completion_items.add_unique(
        helper_items,
        helper_seen,
        "  Alpha  ",
        function(word)
            return { word = word }
        end,
        { base = "al" }
    ),
    "completion add_unique should trim and append matching items"
)
assert(
    helper_items[1] and helper_items[1].word == "Alpha",
    "completion add_unique should pass the normalized word to the factory"
)
assert(
    not completion_items.add_unique(
        helper_items,
        helper_seen,
        "Alpha",
        function(word)
            return { word = word }
        end,
        { base = "al" }
    ),
    "completion add_unique should prevent duplicate keys"
)
local explicit_project_dir = root .. "/tests/fixtures/basic"
local empty_context = buffer_context.current({
    bufnr = 0,
    project = {
        main = explicit_project_dir .. "/main.typ",
    },
})
assert(
    empty_context.file_dir == explicit_project_dir,
    "buffer context should fall back to explicit project main directory"
)

local function find_param(params, name)
    for _, param in ipairs(params or {}) do
        if param.name == name then
            return param
        end
    end
end

local function signature_has_param(label, name)
    local body = type(label) == "string" and label:match("%((.*)%)") or nil
    if not body then
        return false
    end

    for part in body:gmatch("[^,]+") do
        if vim.trim(part):match("^" .. vim.pesc(name) .. ":") then
            return true
        end
    end
    return false
end

local markup_items =
    typst.completion.complete({ base = "tabl", context = "markup", limit = 20 })
local table_item = assert_item(
    markup_items,
    "table",
    "completion should include generated stdlib functions"
)
assert(
    table_item.menu == "[Typst element]",
    "stdlib elements should be labeled"
)
assert(
    table_item.user_data.typst.provider == "stdlib",
    "stdlib completion should expose provider metadata"
)

local native_completion =
    typst.completion.native({ base = "tabl", context = "markup", limit = 20 })
assert(
    native_completion.isIncomplete == false,
    "native completion adapter should return a complete LSP list"
)
assert(
    native_completion.items[1]
        and native_completion.items[1].insertText == "table",
    "native completion adapter should expose LSP insertText"
)
local cmp_items =
    typst.completion.cmp({ base = "tabl", context = "markup", limit = 20 })
assert(
    cmp_items[1] and cmp_items[1].word == "table",
    "cmp adapter should expose cmp-style word fields"
)
local blink_items =
    typst.completion.blink({ base = "tabl", context = "markup", limit = 20 })
assert(
    blink_items[1] and blink_items[1].insertText == "table",
    "blink adapter should expose blink insertText"
)

local cmp_source = typst.completion.cmp_source({
    context = "markup",
    limit = 20,
    include_tinymist = false,
})
local cmp_source_result = nil
cmp_source:complete({
    context = {
        bufnr = vim.api.nvim_get_current_buf(),
        cursor_before_line = "#tabl",
    },
    offset = 5,
}, function(result)
    cmp_source_result = result
end)
assert(
    cmp_source_result
        and cmp_source_result.items[1]
        and cmp_source_result.items[1].word == "table",
    "cmp source adapter should complete from cursor context"
)

local blink_source = typst.completion.blink_source({
    context = "markup",
    limit = 20,
    include_tinymist = false,
})
local blink_source_result = nil
blink_source:get_completions({
    context = {
        bufnr = vim.api.nvim_get_current_buf(),
        cursor_before_line = "#tabl",
    },
    offset = 5,
}, function(result)
    blink_source_result = result
end)
assert(
    blink_source_result
        and blink_source_result.items[1]
        and blink_source_result.items[1].insertText == "table",
    "blink source adapter should complete from cursor context"
)

assert_item(
    typst.completion.complete({
        base = "std.tabl",
        context = "markup",
        limit = 20,
    }),
    "std.table",
    "stdlib completion should support explicit std-qualified names"
)

assert_item(
    typst.completion.complete({
        base = "table.c",
        context = "markup",
        limit = 20,
    }),
    "table.cell",
    "stdlib completion should include nested members"
)

assert_item(
    typst.completion.complete({
        base = "math.equ",
        context = "markup",
        limit = 20,
    }),
    "math.equation",
    "stdlib completion should support explicit math-qualified names outside math"
)

local math_items = typst.completion.complete({
    base = "arrow.r",
    context = "math",
    limit = 20,
})
local arrow_item = assert_item(
    math_items,
    "arrow.r",
    "math completion should insert unqualified symbol names"
)
assert(
    arrow_item.abbr:find("→", 1, true),
    "symbol completion should include the glyph"
)

local explicit_symbol_items = typst.completion.complete({
    base = "sym.arrow.l",
    context = "markup",
    limit = 20,
})
assert_item(
    explicit_symbol_items,
    "sym.arrow.l",
    "explicit symbol completion should preserve the sym prefix outside math"
)

local emoji_items = typst.completion.complete({
    base = "emoji.face.h",
    context = "markup",
    limit = 20,
})
local halo_emoji = assert_item(
    emoji_items,
    "emoji.face.halo",
    "explicit emoji completion should include emoji names"
)
assert(halo_emoji.menu == "[Typst emoji]", "emoji completion should be labeled")

local package_validation_calls = 0
registry_scan.root_signatures = function(...)
    package_validation_calls = package_validation_calls + 1
    return original_root_signatures(...)
end
registry_scan.scan_roots = function(...)
    package_validation_calls = package_validation_calls + 1
    return original_scan_roots(...)
end

local package_items = typst.completion.complete({
    base = "@preview/ce",
    context = "markup",
    limit = 20,
})
assert(
    package_validation_calls == 0,
    "package completion should read prewarmed package records without cache validation"
)
registry_scan.root_signatures = original_root_signatures
registry_scan.scan_roots = original_scan_roots

local cetz_package = assert_item(
    package_items,
    "@preview/cetz:0.3.4",
    "package completion should include cached package specs"
)
assert(
    cetz_package.menu == "[Typst package]",
    "cached package completion should be marked as a package"
)
assert(
    cetz_package.info:find("deterministic drawing package", 1, true),
    "package completion should include manifest descriptions"
)

local template_items = typst.completion.complete({
    base = "@preview/article",
    context = "markup",
    limit = 20,
})
local article_template = assert_item(
    template_items,
    "@preview/article-template:1.0.0",
    "template completion should include cached template packages"
)
assert(
    article_template.menu == "[Typst template]",
    "template packages should be labeled separately"
)
assert(
    article_template.info:find("Template entrypoint: main.typ", 1, true),
    "template completion should expose template metadata"
)

local universe_items = typst.completion.complete({
    base = "@preview/universe",
    context = "markup",
    limit = 20,
})
local universe_package = assert_item(
    universe_items,
    "@preview/universe-only:2.1.0",
    "package completion should include optional Universe index packages"
)
assert(
    universe_package.user_data.typst.provider == "universe",
    "Universe package items should expose their provider"
)
assert(
    universe_package.info:find(
        "Package from optional Universe index data",
        1,
        true
    ),
    "Universe package completion should include index descriptions"
)

local universe_template_items = typst.completion.complete({
    base = "@preview/starter",
    context = "markup",
    limit = 20,
})
local universe_template = assert_item(
    universe_template_items,
    "@preview/starter-template:0.2.0",
    "template completion should include optional Universe index templates"
)
assert(
    universe_template.menu == "[Typst template]",
    "Universe templates should be labeled separately"
)
assert(
    universe_template.user_data.typst.provider == "universe",
    "Universe template items should expose their provider"
)

local csl_items = typst.completion.complete({
    base = "ie",
    context = "csl_style",
    limit = 20,
})
local ieee_style = assert_item(
    csl_items,
    "ieee",
    "CSL style completion should include built-in style IDs"
)
assert(
    ieee_style.menu == "[Typst CSL style]",
    "CSL style completion should be labeled"
)
assert_item(
    typst.completion.complete({
        base = "american-physics",
        context = "csl_style",
        limit = 20,
    }),
    "american-physics-society",
    "CSL style completion should use Typst metadata style IDs"
)

local custom_style_items = typst.completion.complete({
    base = "custom-config",
    context = "csl_style",
    limit = 20,
})
assert_item(
    custom_style_items,
    "custom-config-style",
    "CSL style completion should include configured style IDs"
)

local raw_language_items = typst.completion.complete({
    base = "py",
    context = "raw_language",
    limit = 20,
})
local python_language = assert_item(
    raw_language_items,
    "python",
    "raw language completion should include common IDs"
)
assert(
    python_language.menu == "[Typst raw language]",
    "raw language completion should be labeled"
)

assert_item(
    typst.completion.complete({
        base = "custom-raw",
        context = "raw_language",
        limit = 20,
    }),
    "custom-raw-lang",
    "raw language completion should include configured IDs"
)

assert_item(
    typst.completion.complete({
        base = "c+",
        context = "raw_language",
        limit = 20,
    }),
    "c++",
    "raw language completion should support language IDs with punctuation"
)

local color_items =
    typst.completion.complete({ base = "fuch", context = "color", limit = 20 })
local fuchsia_color = assert_item(
    color_items,
    "fuchsia",
    "color completion should include Typst colors"
)
assert(
    fuchsia_color.menu == "[Typst color]",
    "color completion should be labeled"
)

assert_item(
    typst.completion.complete({ base = "brand", context = "color", limit = 20 }),
    "brand-primary",
    "color completion should include configured names"
)

assert_item(
    typst.completion.complete({
        base = "color.map.vi",
        context = "color",
        limit = 20,
    }),
    "color.map.viridis",
    "color completion should include Typst color maps"
)

local old_metadata_catalog = metadata.catalog
local old_metadata_stdlib_item = metadata.stdlib_item
metadata.catalog = function()
    return { version = "synthetic-color-metadata" }
end
metadata.stdlib_item = function(path)
    if path == "color" then
        return {
            members = {
                ultraviolet = {
                    kind = "constant",
                    type = "color",
                },
            },
        }
    end
    if path == "color.map" then
        return {
            members = {
                spectralish = {
                    kind = "constant",
                    type = "array",
                },
            },
        }
    end
    return old_metadata_stdlib_item(path)
end

local metadata_color_ok, metadata_color_err = pcall(function()
    assert_item(
        typst.completion.complete({
            base = "ultra",
            context = "color",
            limit = 20,
        }),
        "ultraviolet",
        "color completion should read generated stdlib color constants"
    )
    assert_item(
        typst.completion.complete({
            base = "color.ultra",
            context = "color",
            limit = 20,
        }),
        "color.ultraviolet",
        "color completion should expose generated color type members"
    )
    assert_item(
        typst.completion.complete({
            base = "color.map.spect",
            context = "color",
            limit = 20,
        }),
        "color.map.spectralish",
        "color completion should read generated stdlib color maps"
    )
end)
metadata.catalog = old_metadata_catalog
metadata.stdlib_item = old_metadata_stdlib_item
assert(metadata_color_ok, metadata_color_err)

local font_items = typst.completion.complete({
    base = "Unit",
    context = "font_family",
    limit = 20,
})
local configured_font = assert_item(
    font_items,
    "Unit Test Serif",
    "font completion should include configured families"
)
assert(
    configured_font.menu == "[Typst font]",
    "font completion should be labeled"
)

local parameter_items = typst.completion.complete({
    base = "col",
    context = "parameter",
    function_name = "table",
    limit = 20,
})
local columns_parameter = assert_item(
    parameter_items,
    "columns: ",
    "generated stdlib parameter completion should include built-in fields"
)
assert(
    columns_parameter.user_data.typst.provider == "stdlib",
    "stdlib parameters should expose provider metadata"
)
assert(
    columns_parameter.user_data.typst.default == "()",
    "stdlib parameters should expose generated defaults"
)
assert(
    columns_parameter.info:find("column sizes", 1, true),
    "stdlib parameter completion should include generated parameter documentation"
)
assert(
    columns_parameter.user_data.typst.docs:find("column sizes", 1, true),
    "stdlib parameter completion should expose generated parameter docs in user data"
)

assert_item(
    typst.completion.complete({
        base = "gut",
        context = "parameter",
        function_name = "table",
        limit = 20,
    }),
    "gutter: ",
    "ordinary parameter completion should include named non-settable parameters"
)
local set_table_gutter_items = typst.completion.complete({
    base = "gut",
    context = "parameter",
    function_name = "table",
    set_rule = true,
    limit = 20,
})
assert(
    not find_item(set_table_gutter_items, "gutter: "),
    "set-rule parameter completion should hide non-settable generated parameters"
)
local set_table_column_items = typst.completion.complete({
    base = "col",
    context = "parameter",
    function_name = "table",
    set_rule = true,
    limit = 20,
})
local set_columns_parameter = assert_item(
    set_table_column_items,
    "columns: ",
    "set-rule parameter completion should keep settable fields"
)
assert(
    set_columns_parameter.user_data.typst.settable == true
        and set_columns_parameter.user_data.typst.set_rule == true,
    "set-rule parameter completion should expose settable metadata"
)

local fit_value_items = typst.completion.complete({
    base = "co",
    context = "parameter_value",
    function_name = "image",
    parameter_name = "fit",
    limit = 20,
})
local cover_value = assert_item(
    fit_value_items,
    '"cover"',
    "stdlib parameter value completion should include accepted constants"
)
assert_item(
    fit_value_items,
    '"contain"',
    "stdlib parameter value completion should match unquoted prefixes"
)
assert(
    not find_item(fit_value_items, '"stretch"'),
    "parameter value completion should respect the requested prefix"
)
assert(
    cover_value.user_data.typst.provider == "stdlib",
    "parameter values should expose provider metadata"
)
assert(
    cover_value.user_data.typst.parameter_name == "fit",
    "parameter values should expose parameter metadata"
)
assert(
    cover_value.info:find("completely cover the area", 1, true),
    "parameter value completion should include generated CastInfo value docs"
)

assert_item(
    typst.completion.complete({
        base = "it",
        context = "parameter_value",
        function_name = "text",
        parameter_name = "style",
        limit = 20,
    }),
    '"italic"',
    "stdlib parameter value completion should use CastInfo values from other built-ins"
)

local direction_value_items = typst.completion.complete({
    base = "rt",
    context = "parameter_value",
    function_name = "text",
    parameter_name = "dir",
    limit = 20,
})
local rtl_value = assert_item(
    direction_value_items,
    "rtl",
    "stdlib parameter value completion should derive direction constants from generated metadata"
)
assert(
    rtl_value.info:find("Source: rtl", 1, true),
    "typed constant parameter values should expose their source"
)
assert(
    not find_item(direction_value_items, "direction"),
    "parameter value completion should not insert type names"
)

assert_item(
    typst.completion.complete({
        base = "tt",
        context = "parameter_value",
        function_name = "stack",
        parameter_name = "dir",
        limit = 20,
    }),
    "ttb",
    "stdlib parameter value completion should include generated direction values for other built-ins"
)

local alignment_value_items = typst.completion.complete({
    base = "cent",
    context = "parameter_value",
    function_name = "align",
    parameter_name = "alignment",
    limit = 20,
})
assert_item(
    alignment_value_items,
    "center",
    "stdlib parameter value completion should derive alignment constants from generated metadata"
)
assert(
    not find_item(alignment_value_items, "alignment"),
    "parameter value completion should not suggest value type names"
)

vim.cmd.edit(root .. "/tests/fixtures/basic/main.typ")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "#sym.arr",
    "$ arrow.r $",
    "#table(columns: 2, rows: 3)",
})
vim.bo.filetype = "typst"
typst.project.attach(buf)
assert(
    vim.bo[buf].omnifunc == "v:lua.typst_nvim_omnifunc",
    "attach should install typst omnifunc"
)

vim.api.nvim_win_set_cursor(0, { 1, #"#sym.arr" })
assert(
    typst.completion.omnifunc(1, "") == 1,
    "omnifunc should start completion after #"
)
assert(
    find_item(typst.completion.omnifunc(0, "sym.arr"), "sym.arrow"),
    "omnifunc should return symbol completion items"
)

vim.cmd.edit(root .. "/tests/fixtures/basic/chapter.typ")
local existing_buf = vim.api.nvim_get_current_buf()
vim.bo[existing_buf].filetype = "typst"
vim.bo[existing_buf].omnifunc = "custom#complete"
typst.project.attach(existing_buf)
assert(
    vim.bo[existing_buf].omnifunc == "custom#complete",
    "attach should not replace an existing omnifunc"
)

vim.api.nvim_set_current_buf(buf)
vim.api.nvim_win_set_cursor(0, { 3, 20 })
local signature = typst.completion.signature({ bufnr = buf })
assert(
    signature and signature.label:find("table(", 1, true),
    "signature helper should use stdlib function metadata"
)
assert(
    find_param(signature.parameters, "columns"),
    "stdlib signature should expose built-in parameters"
)

vim.cmd.edit(root .. "/tests/fixtures/basic/index-main.typ")
local index_buf = vim.api.nvim_get_current_buf()
vim.bo.filetype = "typst"
local index_project = typst.project.attach(index_buf)
assert(index_project, "fixture project should attach")
local unicode_completion_row = vim.api.nvim_buf_line_count(index_buf)
vim.api.nvim_buf_set_lines(index_buf, -1, -1, false, { "αβ tinymist" })

local original_get_clients = vim.lsp.get_clients
local original_coc_initialized = vim.g.coc_service_initialized
local completion_module = require("typst.completion")
local completion_request_count = 0
local completion_callbacks = {}
local cancelled_completion_requests = {}
vim.lsp.get_clients = function(opts)
    if not opts or opts.bufnr ~= index_buf then
        return {}
    end

    return {
        {
            name = "tinymist",
            offset_encoding = "utf-16",
            supports_method = function(_, method)
                return method == "textDocument/completion"
            end,
            request_sync = function()
                error("completion must not use synchronous Tinymist requests")
            end,
            cancel_request = function(_, request_id)
                cancelled_completion_requests[#cancelled_completion_requests + 1] =
                    request_id
                return true
            end,
            request = function(_, method, params, callback, bufnr)
                completion_request_count = completion_request_count + 1
                assert(
                    method == "textDocument/completion",
                    "completion should request Tinymist completions"
                )
                assert(
                    bufnr == index_buf,
                    "completion should request Tinymist completions for the target buffer"
                )
                if params.position.line == unicode_completion_row then
                    assert(
                        params.position.character == 3,
                        "completion should encode explicit byte positions as UTF-16"
                    )
                else
                    assert(
                        params.position.line == 0,
                        "completion should send the requested LSP position"
                    )
                end
                completion_callbacks[#completion_callbacks + 1] = function()
                    callback(nil, {
                        isIncomplete = false,
                        items = {
                            {
                                label = "tinymist-helper",
                                insertText = "tinymist-helper()",
                                filterText = "tinymist-helper",
                                kind = vim.lsp.protocol.CompletionItemKind.Function,
                                detail = "fn tinymist-helper()",
                                documentation = {
                                    kind = "markdown",
                                    value = "Semantic Tinymist completion",
                                },
                            },
                            {
                                label = "not-the-prefix",
                                insertText = "not-the-prefix",
                            },
                            {
                                label = "tinymist-snippet",
                                textEdit = {
                                    range = {
                                        start = {
                                            line = params.position.line,
                                            character = params.position.character,
                                        },
                                        ["end"] = {
                                            line = params.position.line,
                                            character = params.position.character,
                                        },
                                    },
                                    newText = "tinymist-snippet(${1:value})",
                                },
                                insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
                                filterText = "tinymist-snippet",
                                additionalTextEdits = {
                                    {
                                        range = {
                                            start = { line = 0, character = 0 },
                                            ["end"] = {
                                                line = 0,
                                                character = 0,
                                            },
                                        },
                                        newText = '#import "helpers.typ": helper\n',
                                    },
                                },
                                command = {
                                    title = "resolve",
                                    command = "tinymist.resolve",
                                },
                                data = {
                                    completion_id = 42,
                                },
                            },
                            {
                                label = "tinymist-edit-insert",
                                filterText = "tinymist-edit",
                                textEdit = {
                                    newText = "tinymist-edit()",
                                    insert = {
                                        start = {
                                            line = params.position.line,
                                            character = params.position.character,
                                        },
                                        ["end"] = {
                                            line = params.position.line,
                                            character = params.position.character,
                                        },
                                    },
                                    replace = {
                                        start = {
                                            line = params.position.line,
                                            character = 1,
                                        },
                                        ["end"] = {
                                            line = params.position.line,
                                            character = params.position.character,
                                        },
                                    },
                                },
                            },
                            {
                                label = "tinymist-edit-replace",
                                filterText = "tinymist-edit",
                                textEdit = {
                                    newText = "tinymist-edit()",
                                    insert = {
                                        start = {
                                            line = params.position.line,
                                            character = params.position.character,
                                        },
                                        ["end"] = {
                                            line = params.position.line,
                                            character = params.position.character,
                                        },
                                    },
                                    replace = {
                                        start = {
                                            line = params.position.line,
                                            character = 0,
                                        },
                                        ["end"] = {
                                            line = params.position.line,
                                            character = params.position.character,
                                        },
                                    },
                                },
                            },
                        },
                    })
                end
                return true, completion_request_count
            end,
        },
    }
end

local pending_tinymist_items = typst.completion.complete({
    base = "tinymist",
    context = "markup",
    bufnr = index_buf,
    pos = { 0, 1 },
    limit = 20,
})
assert(
    not find_item(pending_tinymist_items, "tinymist-helper()"),
    "Tinymist completion should not block while the async response is pending"
)
assert(
    completion_request_count == 1,
    "completion should request Tinymist asynchronously"
)
completion_callbacks[1]()
vim.wait(100, function()
    local items = typst.completion.complete({
        base = "tinymist",
        context = "markup",
        bufnr = index_buf,
        pos = { 0, 1 },
        limit = 20,
    })
    return find_item(items, "tinymist-helper()") ~= nil
end)
local tinymist_items = typst.completion.complete({
    base = "tinymist",
    context = "markup",
    bufnr = index_buf,
    pos = { 0, 1 },
    limit = 20,
})
local tinymist_item = assert_item(
    tinymist_items,
    "tinymist-helper()",
    "Tinymist completion should run first"
)
assert(
    tinymist_items[1] == tinymist_item,
    "Tinymist completion should be ordered before fallback items"
)
assert(
    tinymist_item.menu == "[Tinymist]",
    "Tinymist completion should be labeled"
)
assert(
    tinymist_item.user_data.typst.semantic == true,
    "Tinymist completion should be marked semantic"
)
local tinymist_snippet = assert_item(
    tinymist_items,
    "tinymist-snippet(${1:value})",
    "Tinymist completion should preserve snippet text edits"
)
local snippet_payload = tinymist_snippet.user_data.typst.lsp_item
assert(snippet_payload.snippet == true, "snippet format should be preserved")
assert(
    snippet_payload.text_edit
        and snippet_payload.text_edit.newText
            == "tinymist-snippet(${1:value})",
    "LSP textEdit should be preserved"
)
assert(
    snippet_payload.additional_edits
        and snippet_payload.additional_edits[1].newText:match("#import"),
    "LSP additionalTextEdits should be preserved"
)
assert(
    snippet_payload.command
        and snippet_payload.command.command == "tinymist.resolve",
    "LSP completion command should be preserved"
)
assert(
    snippet_payload.data and snippet_payload.data.completion_id == 42,
    "LSP completion data should be preserved"
)
local insert_replace_items = {}
for _, item in ipairs(tinymist_items) do
    local payload = item.user_data
        and item.user_data.typst
        and item.user_data.typst.lsp_item
    if payload and payload.new_text == "tinymist-edit()" then
        insert_replace_items[#insert_replace_items + 1] = item
    end
end
assert(
    #insert_replace_items == 2,
    "Tinymist completions with the same newText but different edits should not collapse"
)
local insert_replace_payload = insert_replace_items[1].user_data.typst.lsp_item
assert(
    insert_replace_payload.insert_range and insert_replace_payload.replace_range,
    "InsertReplaceEdit ranges should be preserved for frontend adapters"
)
local function item_by_label(items, label)
    for _, item in ipairs(items or {}) do
        if item.label == label or item.abbr == label then
            return item
        end
    end
end

local native_snippet = item_by_label(
    typst.completion.native({
        base = "tinymist",
        context = "markup",
        bufnr = index_buf,
        pos = { 0, 1 },
        limit = 20,
    }).items,
    "tinymist-snippet"
)
assert(
    native_snippet
        and native_snippet.textEdit
        and native_snippet.textEdit.newText
            == "tinymist-snippet(${1:value})",
    "native completion should expose Tinymist textEdit"
)
assert(
    native_snippet.insertTextFormat == vim.lsp.protocol.InsertTextFormat.Snippet,
    "native completion should expose Tinymist snippet format"
)
assert(
    native_snippet.additionalTextEdits
        and native_snippet.additionalTextEdits[1].newText:match("#import"),
    "native completion should expose Tinymist additionalTextEdits"
)
local native_edit = item_by_label(
    typst.completion.native({
        base = "tinymist-edit",
        context = "markup",
        bufnr = index_buf,
        pos = { 0, 1 },
        limit = 20,
    }).items,
    "tinymist-edit-insert"
)
assert(
    native_edit
        and native_edit.textEdit
        and native_edit.textEdit.insert
        and native_edit.textEdit.replace,
    "native completion should expose InsertReplaceEdit payloads"
)

local cmp_snippet = item_by_label(
    typst.completion.cmp({
        base = "tinymist",
        context = "markup",
        bufnr = index_buf,
        pos = { 0, 1 },
        limit = 20,
    }),
    "tinymist-snippet"
)
assert(
    cmp_snippet
        and cmp_snippet.textEdit
        and cmp_snippet.command
        and cmp_snippet.command.command == "tinymist.resolve",
    "cmp completion should expose Tinymist edit and command fields"
)
local cmp_edit = item_by_label(
    typst.completion.cmp({
        base = "tinymist-edit",
        context = "markup",
        bufnr = index_buf,
        pos = { 0, 1 },
        limit = 20,
    }),
    "tinymist-edit-insert"
)
assert(
    cmp_edit and cmp_edit.textEdit and cmp_edit.textEdit.replace,
    "cmp completion should expose InsertReplaceEdit payloads"
)

local blink_snippet = item_by_label(
    typst.completion.blink({
        base = "tinymist",
        context = "markup",
        bufnr = index_buf,
        pos = { 0, 1 },
        limit = 20,
    }),
    "tinymist-snippet"
)
assert(
    blink_snippet
        and blink_snippet.textEdit
        and blink_snippet.additionalTextEdits,
    "blink completion should expose Tinymist edit fields"
)
local blink_edit = item_by_label(
    typst.completion.blink({
        base = "tinymist-edit",
        context = "markup",
        bufnr = index_buf,
        pos = { 0, 1 },
        limit = 20,
    }),
    "tinymist-edit-insert"
)
assert(
    blink_edit and blink_edit.textEdit and blink_edit.textEdit.insert,
    "blink completion should expose InsertReplaceEdit payloads"
)

vim.api.nvim_set_current_buf(index_buf)
vim.api.nvim_win_set_cursor(0, { 1, 1 })
local omnifunc_snippet = assert_item(
    typst.completion.omnifunc(0, "tinymist"),
    "tinymist-snippet(${1:value})",
    "omnifunc should still return Tinymist semantic completions"
)
local omnifunc_frontend = omnifunc_snippet.user_data
    and omnifunc_snippet.user_data.typst
    and omnifunc_snippet.user_data.typst.frontend
assert(
    omnifunc_frontend
        and omnifunc_frontend.name == "omnifunc"
        and omnifunc_frontend.applies_lsp_edits == false,
    "omnifunc should explicitly mark unsupported LSP completion application"
)
assert(
    omnifunc_frontend.unsupported.snippet
        and omnifunc_frontend.unsupported.additionalTextEdits
        and omnifunc_frontend.unsupported.command
        and omnifunc_frontend.unsupported.textEdit,
    "omnifunc should report snippet, additional edit, command, and textEdit degradation"
)
local omnifunc_edit = assert_item(
    typst.completion.omnifunc(0, "tinymist-edit"),
    "tinymist-edit()",
    "omnifunc should keep InsertReplaceEdit completions as plain insertions"
)
local omnifunc_edit_frontend = omnifunc_edit.user_data
    and omnifunc_edit.user_data.typst
    and omnifunc_edit.user_data.typst.frontend
assert(
    omnifunc_edit_frontend
        and omnifunc_edit_frontend.unsupported.insertReplaceEdit,
    "omnifunc should explicitly mark InsertReplaceEdit degradation"
)
assert(
    not find_item(tinymist_items, "not-the-prefix"),
    "Tinymist completion should respect the requested base"
)

local unicode_tinymist_items = typst.completion.complete({
    base = "tinymist",
    context = "markup",
    bufnr = index_buf,
    pos = { unicode_completion_row, #"αβ " },
    limit = 20,
})
assert(
    completion_request_count == 2,
    "explicit Unicode completion should request Tinymist asynchronously"
)
completion_callbacks[2]()
vim.wait(100, function()
    local items = typst.completion.complete({
        base = "tinymist",
        context = "markup",
        bufnr = index_buf,
        pos = { unicode_completion_row, #"αβ " },
        limit = 20,
    })
    return find_item(items, "tinymist-helper()") ~= nil
end)
unicode_tinymist_items = typst.completion.complete({
    base = "tinymist",
    context = "markup",
    bufnr = index_buf,
    pos = { unicode_completion_row, #"αβ " },
    limit = 20,
})
assert_item(
    unicode_tinymist_items,
    "tinymist-helper()",
    "Tinymist completion should accept explicit byte positions in Unicode text"
)

local cmp_callbacks = {}
local cmp_refreshes = {}
local cmp_tinymist_source = typst.completion.cmp_source({
    context = "markup",
    bufnr = index_buf,
    pos = { 0, 3 },
    limit = 20,
    cmp_refresh = function(_, refresh_opts)
        cmp_refreshes[#cmp_refreshes + 1] = refresh_opts
    end,
})
cmp_tinymist_source:complete({
    context = {
        bufnr = index_buf,
        cursor_before_line = "#tinymist",
    },
    offset = #"#tinymist",
}, function(result)
    cmp_callbacks[#cmp_callbacks + 1] = result
end)
assert(
    #cmp_callbacks == 1,
    "cmp source should return fallback results immediately"
)
assert(
    completion_request_count == 3,
    "cmp source should request Tinymist asynchronously"
)
completion_callbacks[3]()
assert(
    vim.wait(1000, function()
        return #cmp_refreshes == 1
    end, 10),
    "cmp source should request a frontend refresh when Tinymist results arrive"
)
assert(
    #cmp_callbacks == 1,
    "cmp source should not call the same frontend callback twice"
)
cmp_tinymist_source:complete({
    context = {
        bufnr = index_buf,
        cursor_before_line = "#tinymist",
    },
    offset = #"#tinymist",
}, function(result)
    cmp_callbacks[#cmp_callbacks + 1] = result
end)
assert(
    find_item(cmp_callbacks[2].items, "tinymist-helper()"),
    "refreshed cmp request should include cached Tinymist results"
)

local blink_callbacks = {}
local blink_refreshes = {}
local blink_tinymist_source = typst.completion.blink_source({
    context = "markup",
    bufnr = index_buf,
    pos = { 0, 4 },
    limit = 20,
    blink_refresh = function(_, refresh_opts)
        blink_refreshes[#blink_refreshes + 1] = refresh_opts
    end,
})
blink_tinymist_source:get_completions({
    context = {
        bufnr = index_buf,
        cursor_before_line = "#tinymist",
    },
    offset = #"#tinymist",
}, function(result)
    blink_callbacks[#blink_callbacks + 1] = result
end)
assert(
    #blink_callbacks == 1,
    "blink source should return fallback results immediately"
)
assert(
    completion_request_count == 4,
    "blink source should request Tinymist asynchronously"
)
completion_callbacks[4]()
assert(
    vim.wait(1000, function()
        return #blink_refreshes == 1
    end, 10),
    "blink source should request a frontend refresh when Tinymist results arrive"
)
assert(
    #blink_callbacks == 1,
    "blink source should not call the same frontend callback twice"
)
blink_tinymist_source:get_completions({
    context = {
        bufnr = index_buf,
        cursor_before_line = "#tinymist",
    },
    offset = #"#tinymist",
}, function(result)
    blink_callbacks[#blink_callbacks + 1] = result
end)
assert(
    vim.tbl_filter(function(item)
        return item.insertText == "tinymist-helper()"
    end, blink_callbacks[2].items)[1],
    "refreshed blink request should include cached Tinymist results"
)

local fallback_without_tinymist = typst.completion.complete({
    base = "tl",
    context = "markup",
    bufnr = index_buf,
    include_tinymist = false,
    limit = 200,
})
assert_item(
    fallback_without_tinymist,
    "tls",
    "include_tinymist=false should keep project fallback completion"
)
assert(
    completion_request_count == 4,
    "include_tinymist=false should not request LSP completion"
)

typst.completion.complete({
    base = "cancelme",
    context = "markup",
    bufnr = index_buf,
    pos = { 0, 5 },
    limit = 20,
})
assert(
    completion_request_count == 5,
    "completion should create a cancellable Tinymist request"
)
completion_module.reset()
assert(
    cancelled_completion_requests[1] == 5,
    "completion reset should cancel pending Tinymist requests"
)
completion_callbacks[5]()
vim.wait(20, function()
    return false
end, 1, false)
vim.lsp.get_clients = original_get_clients

local labels = typst.index.labels(index_project)
local has_intro_label = false
for _, item in ipairs(labels or {}) do
    has_intro_label = has_intro_label or item.name == "sec:intro"
end
assert(has_intro_label, "public index API should expose labels")
local citations = typst.index.citations(index_project)
local has_doe_citation = false
for _, item in ipairs(citations or {}) do
    has_doe_citation = has_doe_citation or item.name == "doe2020"
end
assert(has_doe_citation, "public index API should expose bibliography keys")

local project_items = typst.completion.complete({
    base = "sec",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    project_items,
    "sec:intro",
    "project completion should include labels"
)

local citation_items = typst.completion.complete({
    base = "doe",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
local citation_item = assert_item(
    citation_items,
    "doe2020",
    "project completion should include bibliography citation keys"
)
assert(
    citation_item.menu == "[Typst citation]",
    "bibliography key completion should be labeled as a citation"
)
assert(
    citation_item.user_data.typst.kind == "citation",
    "bibliography key completion should preserve citation kind"
)
vim.lsp.get_clients = function(opts)
    if opts and opts.bufnr == index_buf then
        return {
            {
                name = "tinymist",
            },
        }
    end
    return {}
end
assert(
    not find_item(
        typst.completion.complete({
            base = "doe",
            context = "markup",
            bufnr = index_buf,
            limit = 200,
        }),
        "doe2020"
    ),
    "bibliography.completion=auto should avoid project citation fallback when native Tinymist is attached"
)
vim.g.coc_service_initialized = 1
vim.lsp.get_clients = original_get_clients
assert(
    not find_item(
        typst.completion.complete({
            base = "doe",
            context = "markup",
            bufnr = index_buf,
            limit = 200,
        }),
        "doe2020"
    ),
    "bibliography.completion=auto should avoid project citation fallback when coc.nvim appears active"
)
vim.g.coc_service_initialized = original_coc_initialized
vim.lsp.get_clients = original_get_clients
assert_item(
    typst.completion.complete({
        base = "doe",
        context = "markup",
        bufnr = index_buf,
        bibliography_completion = "project",
        limit = 200,
    }),
    "doe2020",
    "bibliography.completion=project should keep project citation completion"
)
assert(
    not find_item(
        typst.completion.complete({
            base = "doe",
            context = "markup",
            bufnr = index_buf,
            bibliography_completion = "tinymist",
            limit = 200,
            include_tinymist = false,
        }),
        "doe2020"
    ),
    "bibliography.completion=tinymist should suppress project citation fallback"
)
assert(
    not find_item(
        typst.completion.complete({
            base = "doe",
            context = "markup",
            bufnr = index_buf,
            bibliography_completion = "off",
            limit = 200,
        }),
        "doe2020"
    ),
    "bibliography.completion=off should suppress project citation fallback"
)

local glossary_items = typst.completion.complete({
    base = "tl",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
local glossary_item = assert_item(
    glossary_items,
    "tls",
    "project completion should include glossary keys"
)
assert(
    glossary_item.menu == "[Typst glossary]",
    "glossary completion should be labeled"
)

local local_items = typst.completion.complete({
    base = "local",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    local_items,
    "local-card",
    "project completion should include local definitions"
)

local original_index_collect = index.collect
index.collect = function()
    return {
        project = {
            main = "C:/Users/Charlie/Project/main.typ",
        },
        definitions = {
            {
                name = "windows-card",
                kind = "function",
                source = {
                    path = "c:\\users\\charlie\\project\\main.typ",
                    lnum = 1,
                    col = 1,
                },
            },
            {
                name = "windows-other-drive",
                kind = "function",
                source = {
                    path = "D:\\users\\charlie\\project\\main.typ",
                    lnum = 1,
                    col = 1,
                },
            },
        },
        imported_bindings = {},
        imports = {},
        labels = {},
        references = {},
        citations = {},
        glossary_entries = {},
        paths = {},
    }
end
local windows_items = typst.completion.complete({
    base = "windows",
    context = "markup",
    bufnr = index_buf,
    limit = 20,
})
index.collect = original_index_collect
assert_item(
    windows_items,
    "windows-card",
    "project completion should include definitions from Windows-equivalent main paths"
)
assert(
    not find_item(windows_items, "windows-other-drive"),
    "project completion should hide definitions outside the Windows-equivalent main path"
)

local local_parameter_items = typst.completion.complete({
    base = "fi",
    context = "parameter",
    function_name = "local-card",
    bufnr = index_buf,
    limit = 20,
})
local fill_parameter = assert_item(
    local_parameter_items,
    "fill: ",
    "project completion should include local function parameters"
)
assert(
    fill_parameter.user_data.typst.provider == "project",
    "local parameter completion should use project metadata"
)
assert(
    fill_parameter.user_data.typst.default == "red",
    "local parameter completion should expose defaults"
)

local multiline_items = typst.completion.complete({
    base = "multi",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    multiline_items,
    "multiline-card",
    "project completion should include multiline local definitions"
)

local multiline_parameter_items = typst.completion.complete({
    base = "st",
    context = "parameter",
    function_name = "multiline-card",
    bufnr = index_buf,
    limit = 20,
})
local stroke_parameter = assert_item(
    multiline_parameter_items,
    "stroke: ",
    "project completion should include multiline local function parameters"
)
assert(
    stroke_parameter.user_data.typst.provider == "project",
    "multiline local parameter completion should use project metadata"
)
assert(
    stroke_parameter.user_data.typst.default == "black",
    "multiline local parameter completion should expose defaults"
)

local import_items = typst.completion.complete({
    base = "helper",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
local helper_item = assert_item(
    import_items,
    "helper-func",
    "project completion should include direct imports"
)
assert(
    helper_item.user_data.typst.semantic == false,
    "project completion should be marked as syntactic"
)
assert_item(
    import_items,
    "helper-alias",
    "project completion should include aliased direct imports"
)
assert_item(
    import_items,
    "helper-multiline",
    "project completion should include multiline aliased imports"
)

local wildcard_items = typst.completion.complete({
    base = "exported",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    wildcard_items,
    "exported-value",
    "project completion should include wildcard file imports"
)
assert_item(
    wildcard_items,
    "exported-multiline",
    "project completion should include multiline import selectors"
)

local reexport_items = typst.completion.complete({
    base = "reexported",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    reexport_items,
    "reexported-helper",
    "project completion should include direct file re-exports"
)
assert_item(
    reexport_items,
    "reexported-alias",
    "project completion should include aliased file re-exports"
)
assert_item(
    reexport_items,
    "reexported.reexported-helper",
    "project completion should include module-alias re-exports"
)
assert_item(
    reexport_items,
    "reexported.reexported-alias",
    "project completion should include module-alias aliased re-exports"
)

local imported_parameter_items = typst.completion.complete({
    base = "to",
    context = "parameter",
    function_name = "helper-func",
    bufnr = index_buf,
    limit = 20,
})
assert_item(
    imported_parameter_items,
    "tone: ",
    "project completion should include directly imported function parameters"
)

local aliased_parameter_items = typst.completion.complete({
    base = "to",
    context = "parameter",
    function_name = "helper-alias",
    bufnr = index_buf,
    limit = 20,
})
assert_item(
    aliased_parameter_items,
    "tone: ",
    "project completion should include aliased imported function parameters"
)

local multiline_import_parameter_items = typst.completion.complete({
    base = "to",
    context = "parameter",
    function_name = "helper-multiline",
    bufnr = index_buf,
    limit = 20,
})
assert_item(
    multiline_import_parameter_items,
    "tone: ",
    "project completion should include multiline imported function parameters"
)

local module_items = typst.completion.complete({
    base = "lib.helper",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    module_items,
    "lib.helper-func",
    "project completion should include imported module members"
)

local hidden_items = typst.completion.complete({
    base = "hidden",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    hidden_items,
    "hidden.hidden-value",
    "project completion should include module-only imported members"
)
assert(
    not find_item(hidden_items, "hidden-value"),
    "project completion should not expose module-only imports as unqualified definitions"
)

local module_parameter_items = typst.completion.complete({
    base = "to",
    context = "parameter",
    function_name = "lib.helper-func",
    bufnr = index_buf,
    limit = 20,
})
assert_item(
    module_parameter_items,
    "tone: ",
    "project completion should include module imported function parameters"
)

local reexport_parameter_items = typst.completion.complete({
    base = "va",
    context = "parameter",
    function_name = "reexported-helper",
    bufnr = index_buf,
    limit = 20,
})
assert_item(
    reexport_parameter_items,
    "variant: ",
    "project completion should include re-exported function parameters"
)

local alias_reexport_parameter_items = typst.completion.complete({
    base = "to",
    context = "parameter",
    function_name = "reexported-alias",
    bufnr = index_buf,
    limit = 20,
})
assert_item(
    alias_reexport_parameter_items,
    "tone: ",
    "project completion should include aliased re-exported function parameters"
)

local module_reexport_parameter_items = typst.completion.complete({
    base = "va",
    context = "parameter",
    function_name = "reexported.reexported-helper",
    bufnr = index_buf,
    limit = 20,
})
assert_item(
    module_reexport_parameter_items,
    "variant: ",
    "project completion should include module re-exported function parameters"
)

local module_alias_reexport_parameter_items = typst.completion.complete({
    base = "to",
    context = "parameter",
    function_name = "reexported.reexported-alias",
    bufnr = index_buf,
    limit = 20,
})
assert_item(
    module_alias_reexport_parameter_items,
    "tone: ",
    "project completion should include module aliased re-exported function parameters"
)

local path_items = typst.completion.complete({
    base = "refs",
    context = "markup",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    path_items,
    "refs.bib",
    "project completion should include referenced file paths"
)
assert_item(
    path_items,
    "refs-multiline.bib",
    "project completion should include multiline referenced file paths"
)

local import_path_items = typst.completion.complete({
    base = "index-",
    context = "path",
    path_kind = "import",
    bufnr = index_buf,
    limit = 200,
})
assert_item(
    import_path_items,
    "index-lib.typ",
    "filesystem path completion should include local Typst imports"
)
assert(
    not find_item(import_path_items, "data.json"),
    "import path completion should filter non-Typst files"
)

local dot_path_root = vim.fn.tempname()
vim.fn.mkdir(dot_path_root .. "/.hidden-project-cache", "p")
vim.fn.writefile({ "= Dot Path" }, dot_path_root .. "/main.typ")
vim.cmd.edit(vim.fn.fnameescape(dot_path_root .. "/main.typ"))
local dot_path_buf = vim.api.nvim_get_current_buf()
local dot_path_items = typst.completion.complete({
    base = ".h",
    context = "path",
    path_kind = "import",
    bufnr = dot_path_buf,
    limit = 200,
})
assert_item(
    dot_path_items,
    ".hidden-project-cache/",
    "path completion should include hidden directories when the prefix starts with a dot"
)
assert(
    not find_item(
        typst.completion.complete({
            base = "t",
            context = "path",
            path_kind = "import",
            bufnr = dot_path_buf,
            limit = 200,
        }),
        ".hidden-project-cache/"
    ),
    "path completion should still hide dot directories without a dot prefix"
)
vim.api.nvim_set_current_buf(index_buf)

local image_path_items = typst.completion.complete({
    base = "di",
    context = "path",
    path_kind = "image",
    bufnr = index_buf,
    limit = 200,
})
local diagram_path = assert_item(
    image_path_items,
    "diagram.svg",
    "image path completion should include image files"
)
assert_item(
    image_path_items,
    "diagram-multiline.svg",
    "image path completion should include multiline image paths"
)
assert(
    diagram_path.menu == "[Typst image path]",
    "image path completion should be labeled"
)
assert(
    not find_item(image_path_items, "data.json"),
    "image path completion should filter data files"
)

assert_item(
    typst.completion.complete({
        base = "re",
        context = "path",
        path_kind = "bibliography",
        bufnr = index_buf,
        limit = 200,
    }),
    "refs.bib",
    "bibliography path completion should include bibliography files"
)
assert_item(
    typst.completion.complete({
        base = "refs-m",
        context = "path",
        path_kind = "bibliography",
        bufnr = index_buf,
        limit = 200,
    }),
    "refs-multiline.bib",
    "bibliography path completion should include multiline bibliography files"
)
assert_item(
    typst.completion.complete({
        base = "da",
        context = "path",
        path_kind = "data",
        bufnr = index_buf,
        limit = 200,
    }),
    "data.json",
    "data path completion should include data files"
)
assert_item(
    typst.completion.complete({
        base = "data-e",
        context = "path",
        path_kind = "data",
        bufnr = index_buf,
        limit = 200,
    }),
    "data-extra.json",
    "data path completion should include multiline read() files"
)

local local_csl_items = typst.completion.complete({
    base = "custom",
    context = "csl_style",
    bufnr = index_buf,
    limit = 200,
})
local local_csl = assert_item(
    local_csl_items,
    "custom-style.csl",
    "CSL completion should include local .csl files"
)
assert_item(
    local_csl_items,
    "custom-multiline-style.csl",
    "CSL completion should include multiline local .csl files"
)
assert(
    local_csl.menu == "[Typst CSL file]",
    "local CSL files should be labeled separately"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    '#bibliography("refs.bib", style: "ie',
})
vim.api.nvim_win_set_cursor(0, { 1, #'#bibliography("refs.bib", style: "ie' })
assert(
    find_item(typst.completion.omnifunc(0, "ie"), "ieee"),
    "omnifunc should complete CSL styles in bibliography style context"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    '#cite(<doe2020>, style: "ap',
})
vim.api.nvim_win_set_cursor(0, { 1, #'#cite(<doe2020>, style: "ap' })
assert(
    find_item(typst.completion.omnifunc(0, "ap"), "apa"),
    "omnifunc should complete CSL styles in citation style context"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "```py",
})
vim.api.nvim_win_set_cursor(0, { 1, #"```py" })
assert(
    typst.completion.omnifunc(1, "") == 3,
    "omnifunc should start raw language completion after the fence"
)
assert(
    find_item(typst.completion.omnifunc(0, "py"), "python"),
    "omnifunc should complete raw-block languages"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    '#image("di',
})
vim.api.nvim_win_set_cursor(0, { 1, #'#image("di' })
assert(
    typst.completion.omnifunc(1, "") == #'#image("',
    "omnifunc should start image path completion after the quote"
)
assert(
    find_item(typst.completion.omnifunc(0, "di"), "diagram.svg"),
    "omnifunc should complete image paths"
)

local image_fit_prefix = '#image("diagram.svg", fit: '
vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    image_fit_prefix .. "co",
})
vim.api.nvim_win_set_cursor(0, { 1, #(image_fit_prefix .. "co") })
assert(
    typst.completion.omnifunc(1, "") == #image_fit_prefix,
    "omnifunc should start parameter-value completion after the value prefix"
)
assert(
    find_item(typst.completion.omnifunc(0, "co"), '"cover"'),
    "omnifunc should complete stdlib parameter values"
)

local quoted_image_fit_prefix = '#image("diagram.svg", fit: "'
vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    quoted_image_fit_prefix .. "co",
})
vim.api.nvim_win_set_cursor(0, { 1, #(quoted_image_fit_prefix .. "co") })
assert(
    typst.completion.omnifunc(1, "") == #quoted_image_fit_prefix,
    "omnifunc should start quoted parameter-value completion after the quote"
)
assert(
    find_item(typst.completion.omnifunc(0, "co"), 'cover"'),
    "quoted parameter-value completion should not insert a second opening quote"
)

local text_direction_prefix = "#text(dir: "
vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    text_direction_prefix .. "rt",
})
vim.api.nvim_win_set_cursor(0, { 1, #(text_direction_prefix .. "rt") })
assert(
    find_item(typst.completion.omnifunc(0, "rt"), "rtl"),
    "omnifunc should complete generated direction constants"
)

local align_alignment_prefix = "#align(alignment: "
vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    align_alignment_prefix .. "cent",
})
vim.api.nvim_win_set_cursor(0, { 1, #(align_alignment_prefix .. "cent") })
assert(
    find_item(typst.completion.omnifunc(0, "cent"), "center"),
    "omnifunc should complete generated alignment constants"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    '#import "index-',
})
vim.api.nvim_win_set_cursor(0, { 1, #'#import "index-' })
assert(
    typst.completion.omnifunc(1, "") == #'#import "',
    "omnifunc should start import path completion after the quote"
)
assert(
    find_item(typst.completion.omnifunc(0, "index-"), "index-lib.typ"),
    "omnifunc should complete import paths"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    '#bibliography("re',
})
vim.api.nvim_win_set_cursor(0, { 1, #'#bibliography("re' })
assert(
    find_item(typst.completion.omnifunc(0, "re"), "refs.bib"),
    "omnifunc should complete bibliography paths"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    '#read("da',
})
vim.api.nvim_win_set_cursor(0, { 1, #'#read("da' })
assert(
    find_item(typst.completion.omnifunc(0, "da"), "data.json"),
    "omnifunc should complete data paths"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    '#import "@preview/ce',
})
vim.api.nvim_win_set_cursor(0, { 1, #'#import "@preview/ce' })
assert(
    typst.completion.omnifunc(1, "") == #'#import "',
    "omnifunc should preserve the full package spec base in imports"
)
assert(
    find_item(
        typst.completion.omnifunc(0, "@preview/ce"),
        "@preview/cetz:0.3.4"
    ),
    "omnifunc should complete package specs inside import strings"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#rect(fill: fuch",
})
vim.api.nvim_win_set_cursor(0, { 1, #"#rect(fill: fuch" })
assert(
    find_item(typst.completion.omnifunc(0, "fuch"), "fuchsia"),
    "omnifunc should complete color names in fill context"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#line(stroke: 2pt + re",
})
vim.api.nvim_win_set_cursor(0, { 1, #"#line(stroke: 2pt + re" })
assert(
    find_item(typst.completion.omnifunc(0, "re"), "red"),
    "omnifunc should complete color names after stroke addition"
)

local font_prefix = '#set text(font: "'
vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    font_prefix .. "Unit",
})
vim.api.nvim_win_set_cursor(0, { 1, #(font_prefix .. "Unit") })
assert(
    typst.completion.omnifunc(1, "") == #font_prefix,
    "omnifunc should start font completion after the string quote"
)
assert(
    find_item(typst.completion.omnifunc(0, "Unit"), "Unit Test Serif"),
    "omnifunc should complete font families"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#let local-card(body, fill: red) = body",
    "#local-card(fi",
})
vim.api.nvim_win_set_cursor(0, { 2, #"#local-card(fi" })
assert(
    find_item(typst.completion.omnifunc(0, "fi"), "fill: "),
    "omnifunc should complete local function parameters"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#let local-card(body, fill: red) = body",
    "#local-card(body, fill: red)",
})
vim.api.nvim_win_set_cursor(0, { 2, #"#local-card(body, fi" })
local local_signature = typst.completion.signature({ bufnr = index_buf })
assert(
    local_signature and local_signature.label == "local-card(body, fill: red)",
    "signature should use local function metadata"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#let local-card(body, fill: red) = body",
    "#local-card(fill: red, fi",
})
vim.api.nvim_win_set_cursor(0, { 2, #"#local-card(fill: red, fi" })
assert(
    not find_item(typst.completion.omnifunc(0, "fi"), "fill: "),
    "parameter completion should skip used names"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#table(co",
})
vim.api.nvim_win_set_cursor(0, { 1, #"#table(co" })
assert(
    typst.completion.omnifunc(1, "") == #"#table(",
    "omnifunc should start named parameter completion after the call paren"
)
assert(
    find_item(typst.completion.omnifunc(0, "co"), "columns: "),
    "omnifunc should use generated stdlib parameters"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#table(columns: 2, co",
})
vim.api.nvim_win_set_cursor(0, { 1, #"#table(columns: 2, co" })
assert(
    not find_item(typst.completion.omnifunc(0, "co"), "columns: "),
    "stdlib parameter completion should skip used names"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#set table(gut",
})
vim.api.nvim_win_set_cursor(0, { 1, #"#set table(gut" })
assert(
    not find_item(typst.completion.omnifunc(0, "gut"), "gutter: "),
    "omnifunc should hide non-settable generated parameters in set rules"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#set table(col",
})
vim.api.nvim_win_set_cursor(0, { 1, #"#set table(col" })
assert(
    find_item(typst.completion.omnifunc(0, "col"), "columns: "),
    "omnifunc should keep settable parameters in set rules"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#set table(columns: 2)",
})
vim.api.nvim_win_set_cursor(0, { 1, #"#set table(columns" })
local set_rule_signature = typst.completion.signature({ bufnr = index_buf })
assert(
    set_rule_signature
        and signature_has_param(set_rule_signature.label, "columns"),
    "signature helper should keep settable fields in set rules"
)
assert(
    not signature_has_param(set_rule_signature.label, "gutter"),
    "signature helper should hide non-settable fields in set rules"
)

vim.api.nvim_buf_set_lines(index_buf, 0, -1, false, {
    "#let glossary-entries = (",
    '  tls: (short: "TLS"),',
    ")",
    '#gls("tl',
})
vim.api.nvim_win_set_cursor(0, { 4, #'#gls("tl' })
assert(
    find_item(typst.completion.omnifunc(0, "tl"), "tls"),
    "omnifunc should complete glossary keys"
)

vim.cmd.edit(root .. "/tests/fixtures/basic/package-doc.typ")
local package_buf = vim.api.nvim_get_current_buf()
vim.bo.filetype = "typst"
typst.project.attach(package_buf)
local imported_package_items = typst.completion.complete({
    base = "@preview/cetz",
    context = "markup",
    bufnr = package_buf,
    limit = 200,
})
local imported_package = assert_item(
    imported_package_items,
    "@preview/cetz:0.3.4",
    "project completion should include package imports already used by the project"
)
assert(
    imported_package.user_data.typst.provider == "project",
    "project package imports should retain project metadata"
)

vim.env.TYPST_PACKAGE_CACHE_PATH = old_package_cache_path
vim.cmd("qa!")
