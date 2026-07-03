local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_services = require("typst.project.services")
local typst = require("typst")
typst.reset()

local calls = {
    compile = 0,
    view = 0,
    format = 0,
    lint = 0,
    grammar = 0,
    index = 0,
    picker = 0,
    toc = 0,
}

local compiler_provider = {
    name = "registered-compiler",
    compile = function(project, callback)
        calls.compile = calls.compile + 1
        local output = project.output
            or (
                project.services
                and project.services.compiler
                and project.services.compiler.output
            )
        vim.fn.mkdir(vim.fn.fnamemodify(output, ":h"), "p")
        vim.fn.writefile({ "%PDF-1.4" }, output)
        project.provider_api_compiled = true
        project.output =
            typst_test_cache_path("provider-api-output/mutated.pdf")
        if project.services and project.services.compiler then
            project.services.compiler.output = project.output
        end
        callback({ code = 0, stale = false })
        return { provider = "registered-compiler" }
    end,
    start = function()
        error("watch should not be called in provider API spec")
    end,
    stop = function(_, callback)
        if callback then
            callback({ code = 0, stale = false, stopped = true })
        end
    end,
    status = function(project)
        return "registered-" .. (project.status or "idle")
    end,
    output = function(project)
        return typst_test_cache_path("provider-api-output/")
            .. vim.fn.fnamemodify(project.main, ":t:r")
            .. ".pdf"
    end,
}

typst.providers.register("compiler", "provider-api-compiler", compiler_provider)
typst.providers.register("viewer", "provider-api-viewer", {
    open = function(path, project)
        calls.view = calls.view + 1
        project.provider_api_viewed = path
    end,
    capabilities = {
        forward = false,
        inverse = false,
    },
})
typst.providers.register("format", "provider-api-format", {
    format = function(bufnr, state, opts)
        calls.format = calls.format + 1
        assert(
            vim.api.nvim_buf_is_valid(bufnr),
            "registered formatter should receive a buffer"
        )
        assert(
            state.root == root,
            "registered formatter should receive project state"
        )
        assert(opts ~= nil, "registered formatter should receive opts")
        state.provider_api_formatted = true
        return {
            ok = true,
            provider = "provider-api-format",
            text = "= Provider API\n",
        }
    end,
})
typst.providers.register("lint", "provider-api-lint", {
    lint = function(_, _, _)
        calls.lint = calls.lint + 1
        return {
            provider = "provider-api-lint",
            output = "tests/fixtures/basic/main.typ:1:1: warning: registered lint",
        }
    end,
})
typst.providers.register("grammar", "provider-api-grammar", {
    check = function(_, _, _)
        calls.grammar = calls.grammar + 1
        return {
            provider = "provider-api-grammar",
            output = "tests/fixtures/basic/main.typ:1:1: warning: registered grammar",
        }
    end,
})
typst.providers.register("index", "provider-api-index", {
    collect = function(project)
        calls.index = calls.index + 1
        project.provider_api_indexed = true
        return {
            items = {
                {
                    kind = "label",
                    name = "provider-api:label",
                    source = {
                        path = project.main,
                        lnum = 1,
                        col = 1,
                    },
                },
            },
        }
    end,
})
typst.providers.register("picker", "provider-api-picker", {
    pick = function(items)
        calls.picker = calls.picker + 1
        return {
            ok = true,
            backend = "provider-api-picker",
            item_count = #items,
        }
    end,
})
typst.providers.register("toc", "provider-api-toc", {
    collect = function(project)
        calls.toc = calls.toc + 1
        project.provider_api_toc = true
        return {
            {
                layer = "provider",
                title = "Provider TOC",
                source = {
                    path = project.main,
                    lnum = 1,
                    col = 1,
                },
            },
        }
    end,
})

assert(
    typst.providers.get("format", "provider-api-format"),
    "registered format provider should be retrievable"
)
assert(
    vim.tbl_contains(typst.providers.names("format"), "provider-api-format"),
    "registered format provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("index"), "provider-api-index"),
    "registered index provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("toc"), "provider-api-toc"),
    "registered TOC provider should be listed"
)

typst.setup({
    root = root,
    compile = {
        provider = "provider-api-compiler",
    },
    viewer = {
        provider = "provider-api-viewer",
    },
    format = {
        provider = "provider-api-format",
    },
    lint = {
        provider = "provider-api-lint",
    },
    grammar = {
        provider = "provider-api-grammar",
    },
    picker = {
        provider = "provider-api-picker",
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
local live_project = assert(require("typst.project.store").get(project.key))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "= Unformatted" })

local compile_done = false
local handle = typst.compiler.compile({}, function(result)
    assert(result.code == 0, "registered compiler should report success")
    compile_done = true
end)
assert(
    handle.provider == "registered-compiler",
    "compile should return the registered provider handle"
)
assert(compile_done, "registered compiler callback should run")
assert(calls.compile == 1, "registered compiler should be called once")
assert(
    typst_test_compiler(project).output:match(
        "provider%-api%-output/main%.pdf$"
    ),
    "registered compiler output should be used"
)
assert(
    live_project.provider_api_compiled == nil,
    "registered compiler should not mutate live project state"
)
assert(
    typst.ui.status().status == "registered-success",
    "status should use registered compiler status"
)

typst.viewer.view({ notify = false })
assert(calls.view == 1, "registered viewer should be called once")
assert(
    live_project.provider_api_viewed == nil,
    "registered viewer should not mutate live project state"
)
assert(
    project_services.viewer(live_project).provider == "provider-api-viewer",
    "project should record registered viewer provider"
)

local format_result = typst.tools.format({ notify = false })
assert(format_result.ok, "registered format provider should succeed")
assert(
    format_result.provider == "provider-api-format",
    "format result should keep registered provider name"
)
assert(calls.format == 1, "registered format provider should be called once")
assert(
    project.provider_api_formatted == nil,
    "registered formatter should not mutate live project state"
)

local lint_result = typst.tools.lint({ notify = false })
assert(
    lint_result.ok and lint_result.diagnostics == 1,
    "registered lint provider should publish diagnostics"
)
assert(
    lint_result.provider == "provider-api-lint",
    "lint result should keep registered provider name"
)
assert(calls.lint == 1, "registered lint provider should be called once")

local grammar_result = typst.tools.grammar({ notify = false })
assert(
    grammar_result.ok and grammar_result.diagnostics == 1,
    "registered grammar provider should publish diagnostics"
)
assert(
    grammar_result.provider == "provider-api-grammar",
    "grammar result should keep registered provider name"
)
assert(calls.grammar == 1, "registered grammar provider should be called once")

local indexed = typst.index.collect({ project = project })
assert(
    vim.tbl_contains(
        vim.tbl_map(function(item)
            return item.name
        end, indexed.labels),
        "provider-api:label"
    ),
    "registered index provider should contribute index items"
)
assert(calls.index >= 1, "registered index provider should be called")
assert(
    project.provider_api_indexed == nil,
    "registered index provider should not mutate live project state"
)

local picker_result = typst.picker.open({
    items = {
        {
            kind = "heading",
            name = "Provider API",
            label = "Provider API",
            source = {
                path = main,
                lnum = 1,
                col = 1,
            },
        },
    },
})
assert(picker_result.ok, "registered picker should succeed")
assert(
    picker_result.backend == "provider-api-picker",
    "picker result should keep registered backend name"
)
assert(picker_result.item_count == 1, "registered picker should receive items")
assert(calls.picker == 1, "registered picker should be called once")

local toc_items =
    require("typst.edit.toc").collect(project, { backend = "treesitter" })
assert(
    vim.tbl_contains(
        vim.tbl_map(function(item)
            return item.title
        end, toc_items),
        "Provider TOC"
    ),
    "registered TOC provider should contribute TOC items"
)
assert(calls.toc == 1, "registered TOC provider should be called once")
assert(
    project.provider_api_toc == nil,
    "registered TOC provider should not mutate live project state"
)

local snapshot = typst.project.snapshot()
assert(
    snapshot.root == project.root,
    "project snapshot should expose project root"
)
snapshot.root = "mutated"
assert(
    project.root == root,
    "project snapshot mutation should not affect live project state"
)

local toc_picker_items =
    typst.picker.items({ kind = "toc", toc_backend = "treesitter" })
assert(
    vim.tbl_contains(
        vim.tbl_map(function(item)
            return item.name
        end, toc_picker_items),
        "[provider] Provider TOC"
    ),
    "registered TOC provider should contribute TOC picker items"
)
assert(calls.toc == 2, "TOC picker should consume registered TOC providers")

local provider_layer_items =
    typst.picker.items({ kind = "provider", toc_backend = "treesitter" })
assert(
    #provider_layer_items == 1,
    "custom TOC layer picker kind should not expand to every picker item"
)
assert(
    provider_layer_items[1].kind == "provider",
    "custom TOC layer should remain the picker item kind"
)
assert(
    provider_layer_items[1].name == "Provider TOC",
    "custom TOC layer picker should use provider item title"
)
assert(
    provider_layer_items[1].toc_layer == "provider",
    "custom TOC layer picker should expose the layer name"
)
assert(
    calls.toc == 3,
    "custom TOC layer picker should consume registered TOC providers"
)

local all_layer_items =
    typst.picker.items({ kind = "all", toc_backend = "treesitter" })
assert(
    vim.tbl_contains(
        vim.tbl_map(function(item)
            return item.kind .. ":" .. item.name
        end, all_layer_items),
        "provider:Provider TOC"
    ),
    "all-kind picker should keep custom TOC layer kinds"
)
assert(
    calls.toc == 4,
    "all-kind picker should consume registered TOC providers"
)

local removed = typst.providers.unregister("format", "provider-api-format")
assert(removed, "unregister_provider should return the removed provider")
assert(
    not typst.providers.get("format", "provider-api-format"),
    "unregistered provider should be removed"
)

vim.cmd("qa!")
