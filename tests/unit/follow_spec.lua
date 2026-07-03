local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local index = require("typst.index")
local project_registry = require("typst.project")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("follow-output"),
})

vim.cmd.enew()
local dashboard_bufnr = vim.api.nvim_get_current_buf()
vim.bo[dashboard_bufnr].filetype = ""
vim.api.nvim_buf_set_lines(dashboard_bufnr, 0, -1, false, { "@missing" })
vim.api.nvim_win_set_cursor(0, { 1, 1 })
local before_dashboard_follow = vim.tbl_count(project_registry.all())
assert(
    typst.navigation.follow({ open = false }) == nil,
    "follow from a dashboard buffer should not resolve project targets"
)
assert(
    vim.tbl_count(project_registry.all()) == before_dashboard_follow,
    "follow from a dashboard buffer should not create a project"
)

local main = root .. "/tests/fixtures/basic/index-main.typ"
vim.cmd.edit(main)
vim.bo.filetype = "typst"
typst.project.attach(0)

local function place_on(needle)
    local bufnr = vim.api.nvim_get_current_buf()
    for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        local start_col = line:find(needle, 1, true)
        if start_col then
            vim.api.nvim_win_set_cursor(0, { index, start_col - 1 })
            return
        end
    end
    error("fixture missing text: " .. needle)
end

local function assert_target(needle, kind, check)
    place_on(needle)
    local target = assert(
        typst.navigation.follow({ open = false }),
        "missing follow target for " .. needle
    )
    assert(
        target.kind == kind,
        ("expected %s target for %s, got %s"):format(kind, needle, target.kind)
    )
    if check then
        check(target)
    end
    return target
end

local function assert_no_target(needle, message)
    place_on(needle)
    local target = typst.navigation.follow({ open = false })
    assert(
        target == nil,
        message or ("expected no follow target for " .. needle)
    )
end

assert_target("index-lib.typ", "path", function(target)
    assert(
        target.path:match("index%-lib%.typ$"),
        "import path target should point at index-lib.typ"
    )
end)

assert_target("@preview/cetz:0.3.4", "package", function(target)
    assert(
        target.spec == "@preview/cetz:0.3.4",
        "package target should preserve exact package spec"
    )
end)

assert_target("diagram.svg", "path", function(target)
    assert(
        target.path:match("diagram%.svg$"),
        "image target should point at diagram.svg"
    )
end)

assert_target("refs.bib", "path", function(target)
    assert(
        target.path:match("refs%.bib$"),
        "bibliography target should point at refs.bib"
    )
end)

assert_target("refs.yml", "path", function(target)
    assert(
        target.path:match("refs%.yml$"),
        "Hayagriva bibliography target should point at refs.yml"
    )
end)

assert_target("data.json", "path", function(target)
    assert(
        target.path:match("data%.json$"),
        "read target should point at data.json"
    )
end)

assert_target("https://example.com/typst", "url", function(target)
    assert(
        target.url == "https://example.com/typst",
        "URL target should preserve the URL"
    )
end)

assert_no_target(
    "@fake-comment",
    "comment shorthand references should not resolve follow targets"
)
assert_no_target(
    "fake.typ",
    "comment import paths should not resolve follow targets"
)
assert_no_target(
    "fake.svg",
    "comment image paths should not resolve follow targets"
)
assert_no_target(
    "fake-string",
    "ordinary strings should not resolve follow targets"
)
assert_no_target(
    "@fake-inline",
    "inline raw shorthand references should not resolve follow targets"
)
assert_no_target(
    "fake-inline.typ",
    "inline raw paths should not resolve follow targets"
)
assert_no_target(
    "@fake-block",
    "block comment references should not resolve follow targets"
)
assert_no_target(
    "fake-block.typ",
    "block comment paths should not resolve follow targets"
)
assert_no_target(
    "@fake-raw",
    "fenced raw references should not resolve follow targets"
)
assert_no_target(
    "fake-raw.typ",
    "fenced raw paths should not resolve follow targets"
)

assert_target("@sec:intro", "label", function(target)
    assert(
        target.name == "sec:intro",
        "reference target should resolve to label definition"
    )
    assert(target.path == main, "label target should point at the main fixture")
    assert(target.lnum == 1, "label target should point at the label line")
end)

assert_target("@apostrophe:label", "label", function(target)
    assert(
        target.name == "apostrophe:label",
        "contractions should not hide later follow targets"
    )
end)

assert_target("@doe2020", "citation", function(target)
    assert(
        target.path:match("refs%.bib$"),
        "citation target should point at the bibliography file"
    )
end)

assert_target("@yaml2022", "citation", function(target)
    assert(
        target.path:match("refs%.yml$"),
        "Hayagriva citation target should point at the bibliography file"
    )
end)

local ambiguous_dir = typst_test_cache_path("follow-ambiguous")
vim.fn.mkdir(ambiguous_dir, "p")
local ambiguous_main = ambiguous_dir .. "/main.typ"
local ambiguous_bib = ambiguous_dir .. "/refs.bib"
vim.fn.writefile({
    "@article{same-key,",
    "  title = {Same Key Citation},",
    "}",
}, ambiguous_bib)
vim.fn.writefile({
    "= Same <same-key>",
    '#bibliography("refs.bib")',
    "Text @same-key.",
    "#cite(<same-key>)",
}, ambiguous_main)
vim.cmd.edit(ambiguous_main)
vim.bo.filetype = "typst"
typst.project.set_main(ambiguous_main)

assert_target("@same-key", "label", function(target)
    assert(
        target.name == "same-key",
        "ambiguous shorthand reference should preserve label fallback"
    )
    assert(
        target.path == ambiguous_main,
        "ambiguous shorthand reference should resolve to the label definition"
    )
end)

assert_target("cite(<same-key>)", "citation", function(target)
    assert(
        target.name == "same-key",
        "explicit cite target should preserve citation key"
    )
    assert(
        target.path == ambiguous_bib,
        "explicit cite target should resolve to bibliography entry"
    )
end)

local csl_dir = typst_test_cache_path("follow-csl")
vim.fn.mkdir(csl_dir, "p")
local csl_main = csl_dir .. "/main.typ"
local csl_bib = csl_dir .. "/refs.bib"
local csl_file = csl_dir .. "/custom-style.csl"
vim.fn.writefile({
    "@article{csl-key,",
    "  title = {CSL Fixture},",
    "}",
}, csl_bib)
vim.fn.writefile({
    '<style xmlns="http://purl.org/net/xbiblio/csl" version="1.0"></style>',
}, csl_file)
vim.fn.writefile({
    '#bibliography("refs.bib", style: "custom-style.csl")',
    '#bibliography("refs.bib", style: "ieee")',
    '#bibliography("refs.bib", title: "References")',
}, csl_main)
vim.cmd.edit(csl_main)
vim.bo.filetype = "typst"
typst.project.set_main(csl_main)

assert_target("custom-style.csl", "path", function(target)
    assert(
        target.path == csl_file,
        "local CSL style target should resolve to the CSL file"
    )
    assert(
        target.path_kind == "csl_style",
        "local CSL style target should expose path_kind"
    )
end)
assert_no_target(
    "ieee",
    "built-in CSL style IDs should not resolve to nonexistent files"
)
assert_no_target(
    "References",
    "non-source bibliography named strings should not resolve as paths"
)

vim.cmd.edit(main)
vim.bo.filetype = "typst"
typst.project.set_main(main)

assert_target("local-card[Body]", "definition", function(target)
    assert(
        target.name == "local-card",
        "local function target should resolve by name"
    )
    assert(
        target.path == main,
        "local function target should point at the main fixture"
    )
end)

assert_target("helper-func[Imported]", "definition", function(target)
    assert(
        target.imported_name == "helper-func",
        "direct import target should preserve imported name"
    )
    assert(
        target.path:match("index%-lib%.typ$"),
        "direct import target should point at imported source"
    )
end)

assert_target("helper-alias[Aliased import]", "definition", function(target)
    assert(
        target.name == "helper-alias",
        "aliased import target should preserve local name"
    )
    assert(
        target.imported_name == "helper-func",
        "aliased import target should preserve source name"
    )
    assert(
        target.path:match("index%-lib%.typ$"),
        "aliased import target should point at imported source"
    )
end)

assert_target("exported-value", "definition", function(target)
    assert(
        target.imported_name == "exported-value",
        "wildcard import target should preserve imported name"
    )
    assert(
        target.path:match("index%-lib%.typ$"),
        "wildcard import target should point at imported source"
    )
end)

assert_target("lib.helper-func", "definition", function(target)
    assert(
        target.name == "lib.helper-func",
        "module member target should preserve qualified name"
    )
    assert(
        target.path:match("index%-lib%.typ$"),
        "module member target should point at imported source"
    )
end)

assert_target("hidden.hidden-value", "definition", function(target)
    assert(
        target.name == "hidden.hidden-value",
        "module-only target should preserve qualified name"
    )
    assert(
        target.path:match("index%-hidden%.typ$"),
        "module-only target should point at imported source"
    )
end)

assert_target("reexported-helper[Reexported]", "definition", function(target)
    assert(
        target.imported_name == "reexported-helper",
        "re-export target should preserve imported name"
    )
    assert(
        target.path:match("index%-leaf%.typ$"),
        "re-export target should point at the leaf source"
    )
end)

assert_target(
    "reexported-alias[Reexported alias]",
    "definition",
    function(target)
        assert(
            target.imported_name == "aliased-helper",
            "aliased re-export target should preserve source name"
        )
        assert(
            target.path:match("index%-leaf%.typ$"),
            "aliased re-export target should point at the leaf source"
        )
    end
)

assert_target("reexported.reexported-helper", "definition", function(target)
    assert(
        target.name == "reexported.reexported-helper",
        "module re-export target should preserve qualified name"
    )
    assert(
        target.path:match("index%-leaf%.typ$"),
        "module re-export target should point at the leaf source"
    )
end)

assert_target("reexported.reexported-alias", "definition", function(target)
    assert(
        target.name == "reexported.reexported-alias",
        "module aliased re-export target should preserve qualified name"
    )
    assert(
        target.imported_name == "aliased-helper",
        "module aliased re-export target should preserve source name"
    )
    assert(
        target.path:match("index%-leaf%.typ$"),
        "module aliased re-export target should point at the leaf source"
    )
end)

local unicode_dir = typst_test_cache_path("follow-unicode")
vim.fn.mkdir(unicode_dir, "p")
local unicode_main = unicode_dir .. "/main.typ"
vim.fn.writefile({
    "αβ tinymistTarget",
}, unicode_main)
vim.cmd.edit(unicode_main)
vim.bo.filetype = "typst"
typst.project.set_main(unicode_main)

local unicode_bufnr = vim.api.nvim_get_current_buf()
local original_get_clients = vim.lsp.get_clients
local requested_position = nil
vim.lsp.get_clients = function(opts)
    if opts and opts.bufnr == unicode_bufnr then
        return {
            {
                name = "tinymist",
                offset_encoding = "utf-16",
                request = function(_, method, params, callback, request_bufnr)
                    assert(
                        method == "textDocument/definition",
                        "follow should request Tinymist definition"
                    )
                    assert(
                        request_bufnr == unicode_bufnr,
                        "follow should request definition for the target buffer"
                    )
                    requested_position = params.position
                    callback(nil, {
                        uri = vim.uri_from_fname(unicode_main),
                        range = {
                            start = { line = 0, character = 3 },
                            ["end"] = { line = 0, character = 17 },
                        },
                    })
                    return true, 1
                end,
            },
        }
    end
    return {}
end

local unicode_target = nil
local unicode_pending = typst.navigation.follow({
    open = false,
    pos = { 0, #"αβ " },
    callback = function(target)
        unicode_target = target
    end,
})
assert(
    unicode_pending and unicode_pending.pending,
    "Tinymist follow should use an async definition request"
)
assert(requested_position, "Tinymist follow should issue a definition request")
vim.lsp.get_clients = original_get_clients
assert(
    requested_position and requested_position.character == 3,
    "follow should encode byte positions as UTF-16"
)

vim.cmd.edit(main)
vim.bo.filetype = "typst"
typst.project.set_main(main)

place_on("index-lib.typ")
local opened = typst.navigation.follow()
assert(
    opened and opened.kind == "path",
    "follow() should return the opened path target"
)
assert(
    vim.api.nvim_buf_get_name(0):match("index%-lib%.typ$"),
    "follow() should edit file path targets"
)

vim.cmd.enew()
local scratch_bufnr = vim.api.nvim_get_current_buf()
vim.bo[scratch_bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, {
    "= Scratch <scratch:label>",
    "See @scratch:label.",
    "#let scratch-func(body) = body",
    "#scratch-func[Body]",
})
local scratch_project = assert(
    typst.project.attach(scratch_bufnr),
    "scratch follow fixture should attach"
)
assert(
    scratch_project.resolutions[scratch_bufnr].scratch == true,
    "scratch follow fixture should be unnamed"
)

assert_target("@scratch:label", "label", function(target)
    assert(
        target.bufnr == scratch_bufnr,
        "scratch label target should preserve the live buffer"
    )
    assert(
        target.path == scratch_project.main,
        "scratch label target should keep the scratch index key"
    )
end)

local scratch_opened = typst.navigation.follow()
assert(
    scratch_opened and scratch_opened.kind == "label",
    "scratch follow should return the opened label target"
)
assert(
    vim.api.nvim_get_current_buf() == scratch_bufnr,
    "scratch follow should jump within the live buffer instead of editing a synthetic path"
)
assert(
    vim.api.nvim_win_get_cursor(0)[1] == 1,
    "scratch follow should jump to the label line"
)

assert_target("scratch-func[Body]", "definition", function(target)
    assert(
        target.bufnr == scratch_bufnr,
        "scratch definition target should preserve the live buffer"
    )
    assert(
        target.path == scratch_project.main,
        "scratch definition target should keep the scratch index key"
    )
end)

vim.cmd.enew()
local windows_bufnr = vim.api.nvim_get_current_buf()
vim.bo[windows_bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(windows_bufnr, 0, -1, false, { "windows-card()" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local windows_project = {
    root = "C:/Users/Charlie/Project",
    main = "C:/Users/Charlie/Project/main.typ",
}
local old_project_get = project_registry.get
local old_project_resolve = project_registry.resolve
local old_index_collect = index.collect
project_registry.get = function(bufnr)
    return bufnr == windows_bufnr and windows_project or old_project_get(bufnr)
end
project_registry.resolve = function(bufnr)
    return bufnr == windows_bufnr and windows_project
        or old_project_resolve(bufnr)
end
index.collect = function()
    return {
        imported_bindings = {
            {
                name = "windows-card",
                imported_name = "card",
                source = {
                    path = "c:\\users\\charlie\\project\\main.typ",
                    lnum = 1,
                    col = 1,
                },
                definition = {
                    path = "C:/Users/Charlie/Project/lib.typ",
                    lnum = 3,
                    col = 5,
                },
            },
        },
        definitions = {},
        labels = {},
        citations = {},
    }
end

local windows_target = assert(
    typst.navigation.follow({ open = false }),
    "follow should resolve imported bindings from Windows-equivalent main paths"
)
index.collect = old_index_collect
project_registry.get = old_project_get
project_registry.resolve = old_project_resolve

assert(
    windows_target.kind == "definition",
    "Windows-equivalent imported binding should resolve as a definition"
)
assert(
    windows_target.path == "C:/Users/Charlie/Project/lib.typ",
    "follow should return the imported definition location"
)

local uv = vim.uv or vim.loop
local symlink_dir = typst_test_cache_path("follow-loaded-symlink-")
    .. tostring(uv.hrtime())
vim.fn.mkdir(symlink_dir, "p")
local symlink_main = symlink_dir .. "/main.typ"
local canonical_target = symlink_dir .. "/target.typ"
local linked_target = symlink_dir .. "/target-link.typ"
vim.fn.writefile({ "See @linked-label." }, symlink_main)
vim.fn.writefile({ "= Target <linked-label>" }, canonical_target)
if uv.fs_symlink(canonical_target, linked_target) then
    local linked_bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(linked_bufnr, linked_target)
    vim.bo[linked_bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(
        linked_bufnr,
        0,
        -1,
        false,
        { "= Target <linked-label>" }
    )

    vim.cmd.edit(vim.fn.fnameescape(symlink_main))
    vim.bo.filetype = "typst"
    local symlink_bufnr = vim.api.nvim_get_current_buf()
    local symlink_project = {
        root = symlink_dir,
        main = symlink_main,
        bufs = {
            [symlink_bufnr] = true,
        },
    }
    local saved_project_get = project_registry.get
    local saved_project_resolve = project_registry.resolve
    local saved_index_collect = index.collect
    project_registry.get = function(bufnr)
        return bufnr == symlink_bufnr and symlink_project
            or saved_project_get(bufnr)
    end
    project_registry.resolve = function(bufnr)
        return bufnr == symlink_bufnr and symlink_project
            or saved_project_resolve(bufnr)
    end
    index.collect = function()
        return {
            labels = {
                {
                    name = "linked-label",
                    source = {
                        path = canonical_target,
                        lnum = 1,
                        col = 1,
                    },
                },
            },
            citations = {},
            definitions = {},
            imported_bindings = {},
        }
    end

    place_on("@linked-label")
    local symlink_target = assert(
        typst.navigation.follow({ open = false }),
        "follow should resolve equivalent-path loaded target buffers"
    )
    index.collect = saved_index_collect
    project_registry.get = saved_project_get
    project_registry.resolve = saved_project_resolve

    assert(
        symlink_target.bufnr == linked_bufnr,
        "follow targets should keep loaded equivalent-path buffers"
    )
end

vim.cmd("qa!")
