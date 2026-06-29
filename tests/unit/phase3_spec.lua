local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")
typst.reset()

local calls = {
    export = 0,
    async_export = 0,
    eval = 0,
    init = 0,
    profile = 0,
    test = 0,
    bench = 0,
    coverage = 0,
    semantic = 0,
}

typst.providers.register("export", "phase3-export", {
    export = function(project, opts)
        calls.export = calls.export + 1
        local artifact = opts.output_path
        vim.fn.mkdir(vim.fn.fnamemodify(artifact, ":h"), "p")
        assert(
            vim.fn.writefile({ "artifact" }, artifact) == 0,
            "failed to create provider artifact"
        )
        return {
            ok = true,
            artifacts = {
                {
                    format = opts.format or "pdf",
                    path = artifact,
                    provider = "phase3-export",
                },
            },
        }
    end,
})

typst.providers.register("export", "phase3-async-export", {
    export = function(project, opts, callback)
        calls.async_export = calls.async_export + 1
        local artifact = opts.output_path
        vim.schedule(function()
            vim.fn.mkdir(vim.fn.fnamemodify(artifact, ":h"), "p")
            assert(
                vim.fn.writefile({ "async artifact" }, artifact) == 0,
                "failed to create async provider artifact"
            )
            callback({
                ok = true,
                artifacts = {
                    {
                        format = opts.format or "pdf",
                        path = artifact,
                        provider = "phase3-async-export",
                    },
                },
            })
        end)
        return {
            ok = true,
            pending = true,
            provider = "phase3-async-export",
            path = opts.output_path,
        }
    end,
})

typst.providers.register("export", "phase3-undeclared-export", {
    export = function(project, opts)
        local artifact = typst_test_cache_path("phase3/undeclared.")
            .. (opts.format or "pdf")
        vim.fn.mkdir(vim.fn.fnamemodify(artifact, ":h"), "p")
        assert(
            vim.fn.writefile({ "undeclared artifact" }, artifact) == 0,
            "failed to create undeclared provider artifact"
        )
        return {
            ok = true,
            artifacts = {
                {
                    format = opts.format or "pdf",
                    path = artifact,
                    provider = "phase3-undeclared-export",
                },
            },
        }
    end,
})

typst.providers.register("eval", "phase3-eval", {
    eval = function(_, opts)
        calls.eval = calls.eval + 1
        return {
            ok = true,
            expression = opts.expression,
            value = "evaluated:" .. opts.expression,
        }
    end,
})

typst.providers.register("init", "phase3-init", {
    init = function(opts)
        calls.init = calls.init + 1
        return {
            ok = true,
            template = opts.template,
            destination = opts.destination or opts.directory,
        }
    end,
})

for _, kind in ipairs({ "profile", "test", "bench", "coverage" }) do
    typst.providers.register(kind, "phase3-" .. kind, {
        run = function(_, opts)
            calls[kind] = calls[kind] + 1
            return {
                ok = true,
                kind = kind,
                args = opts.args,
            }
        end,
    })
end

typst.providers.register("semantic", "phase3-semantic", {
    color_info = function()
        calls.semantic = calls.semantic + 1
        return {
            ok = true,
            count = 1,
            colors = {
                { color = { red = 1, green = 0, blue = 0, alpha = 1 } },
            },
        }
    end,
    references = function()
        calls.semantic = calls.semantic + 1
        return {
            ok = true,
            count = 1,
            references = {},
        }
    end,
})

assert(
    vim.tbl_contains(typst.providers.names("export"), "phase3-export"),
    "export provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("eval"), "phase3-eval"),
    "eval provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("init"), "phase3-init"),
    "init provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("profile"), "phase3-profile"),
    "profile provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("test"), "phase3-test"),
    "test provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("bench"), "phase3-bench"),
    "bench provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("coverage"), "phase3-coverage"),
    "coverage provider should be listed"
)
assert(
    vim.tbl_contains(typst.providers.names("semantic"), "phase3-semantic"),
    "semantic provider should be listed"
)

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("phase3-output"),
    exports = {
        default = "release",
        profiles = {
            release = {
                { format = "pdf", pdf_standard = { "a-2b" } },
                { format = "html", pretty = true },
            },
            provider_txt = {
                format = "txt",
                output_name = "provider-text",
                provider = "phase3-export",
            },
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local exported =
    typst.artifact.export({ provider = "phase3-export", format = "svg" })
assert(exported.ok, "provider-backed export should succeed")
assert(calls.export == 1, "export provider should be called once")

local undeclared = typst.artifact.export({
    provider = "phase3-undeclared-export",
    format = "svg",
})
assert(
    not undeclared.ok and undeclared.reason == "undeclared_output",
    "provider-backed export should reject unreserved artifact paths"
)

local artifacts = typst.artifact.list({ format = "svg" })
assert(#artifacts == 1, "provider-backed export should register one artifact")
assert(artifacts[1].format == "svg", "artifact should preserve format")
assert(
    vim.fn.filereadable(artifacts[1].path) == 1,
    "artifact file should exist"
)

local cleaned = typst.artifact.clean({ format = "svg" })
assert(cleaned.ok, "artifact_clean should succeed")
assert(
    cleaned.count == 1,
    "artifact_clean should delete the registered artifact"
)
assert(
    vim.fn.filereadable(artifacts[1].path) == 0,
    "artifact file should be deleted"
)

local profile_provider_export =
    typst.artifact.export({ profile = "provider_txt" })
assert(
    profile_provider_export.ok,
    "profile-level provider export should succeed"
)
assert(calls.export == 2, "profile-level provider should be called")
local provider_txt = typst.artifact.list({ format = "txt" })
assert(
    #provider_txt == 1,
    "profile-level provider should register txt artifact"
)
assert(
    provider_txt[1].path:match("provider%-text%.txt$"),
    "profile-level provider should use profile output path"
)
assert(
    provider_txt[1].provider == "phase3-export",
    "profile-level provider should preserve provider metadata"
)
assert(
    typst.artifact.clean({ format = "txt" }).count == 1,
    "profile-level provider artifact should clean"
)

vim.cmd("TypstExport provider_txt")
assert(
    calls.export == 3,
    ":TypstExport profile-level provider should call export provider"
)
local command_provider_txt = typst.artifact.list({ format = "txt" })
assert(
    #command_provider_txt == 1,
    ":TypstExport profile-level provider should register txt artifact"
)
assert(
    command_provider_txt[1].path:match("provider%-text%.txt$"),
    ":TypstExport profile-level provider should preserve profile output path"
)
assert(
    typst.artifact.clean({ format = "txt" }).count == 1,
    ":TypstExport profile-level provider artifact should clean"
)

local async_exported = nil
local async_pending = typst.artifact.export(
    { provider = "phase3-async-export", format = "svg" },
    function(result)
        async_exported = result
    end
)
assert(
    async_pending.ok and async_pending.pending,
    "async export provider should return a pending result"
)
assert(calls.async_export == 1, "async export provider should be called once")
local blocked_async_export = typst.artifact.export({
    provider = "phase3-async-export",
    format = "svg",
})
assert(
    not blocked_async_export.ok
        and blocked_async_export.reason == "active_output",
    "pending export provider should reserve its planned output path"
)
assert(
    calls.async_export == 1,
    "active output collision should not invoke the export provider again"
)
assert(
    vim.wait(1000, function()
        return async_exported ~= nil
    end, 10),
    "async export provider callback did not run"
)
assert(async_exported.ok, "async export provider should succeed")

local async_artifacts = typst.artifact.list({ format = "svg" })
assert(
    #async_artifacts == 1,
    "async provider callback should register one artifact"
)
assert(
    async_artifacts[1].provider == "phase3-async-export",
    "async provider artifact should preserve provider metadata"
)
assert(
    vim.fn.filereadable(async_artifacts[1].path) == 1,
    "async provider artifact file should exist"
)
local async_cleaned = typst.artifact.clean({ format = "svg" })
assert(
    async_cleaned.count == 1,
    "artifact_clean should delete async provider artifacts"
)

local evaluated =
    typst.evaluation.eval({ provider = "phase3-eval", expression = "1 + 1" })
assert(
    evaluated.ok and evaluated.value == "evaluated:1 + 1",
    "eval provider should return result"
)
assert(calls.eval == 1, "eval provider should be called once")

local initialized = typst.template.init({
    provider = "phase3-init",
    template = "@preview/example:1.0.0",
    destination = typst_test_cache_path("phase3-template"),
})
assert(initialized.ok, "init provider should return success")
assert(calls.init == 1, "init provider should be called once")

local gallery = typst.template.list({
    universe_index_paths = { root .. "/tests/fixtures/universe-index.json" },
})
local gallery_template = nil
for _, item in ipairs(gallery) do
    if item.spec == "@preview/starter-template:0.2.0" then
        gallery_template = item
        break
    end
end
assert(
    gallery_template,
    "template gallery should include configured Universe-index templates"
)
assert(
    gallery_template.source == "universe_index",
    "Universe gallery templates should report their source"
)
assert(
    gallery_template.template.path == "template",
    "template gallery should preserve template path metadata"
)

local old_select = vim.ui.select
local selected_prompt = nil
vim.ui.select = function(items, opts, on_choice)
    selected_prompt = opts.prompt
    on_choice(items[1])
end
local selected_init = typst.template.init({
    provider = "phase3-init",
    select = true,
    universe_index_paths = { root .. "/tests/fixtures/universe-index.json" },
    destination = typst_test_cache_path("phase3-selected-template"),
})
vim.ui.select = old_select
assert(
    selected_init.ok and selected_init.pending,
    "template init selection should return a pending selection result"
)
assert(
    selected_prompt == "Typst template",
    "template init selection should use a clear prompt"
)
assert(
    calls.init == 2,
    "template init selection should initialize the chosen template"
)

assert(
    typst.development.profile({ provider = "phase3-profile" }).ok,
    "profile provider should return success"
)
assert(
    typst.development.test({ provider = "phase3-test", args = "--all" }).ok,
    "test provider should return success"
)
assert(
    typst.development.bench({ provider = "phase3-bench" }).ok,
    "bench provider should return success"
)
assert(
    typst.development.coverage({ provider = "phase3-coverage" }).ok,
    "coverage provider should return success"
)
assert(calls.profile == 1, "profile provider should be called once")
assert(calls.test == 1, "test provider should be called once")
assert(calls.bench == 1, "bench provider should be called once")
assert(calls.coverage == 1, "coverage provider should be called once")

local semantic = typst.semantic.color_info({ provider = "phase3-semantic" })
assert(
    semantic.ok and semantic.count == 1,
    "semantic color provider should return result"
)
assert(calls.semantic == 1, "semantic provider should be called once")

local old_get_clients = vim.lsp.get_clients
local semantic_source_buf = vim.api.nvim_get_current_buf()
vim.lsp.get_clients = function()
    return {
        {
            name = "tinymist",
            supports_method = function()
                return true
            end,
            request = function(_, method, _, callback)
                if method == "textDocument/documentColor" then
                    callback(nil, {
                        {
                            color = {
                                red = 1,
                                green = 0,
                                blue = 0,
                                alpha = 1,
                            },
                            range = { start = { line = 0, character = 0 } },
                        },
                    })
                    return true, 1
                end
                if method == "textDocument/codeLens" then
                    callback(nil, {
                        {
                            range = { start = { line = 0, character = 0 } },
                            command = {
                                title = "Export PDF",
                                command = "tinymist.exportPdf",
                            },
                        },
                    })
                    return true, 2
                end
            end,
        },
    }
end
local semantic_colors = nil
local semantic_color_pending = typst.semantic.color_info({
    open = true,
    bufnr = semantic_source_buf,
    callback = function(result)
        semantic_colors = result
    end,
})
vim.lsp.get_clients = old_get_clients
assert(
    semantic_color_pending and semantic_color_pending.pending,
    "Tinymist color info should return a pending request"
)
assert(
    vim.wait(100, function()
        return semantic_colors ~= nil
    end),
    "Tinymist color info should finish asynchronously"
)
assert(
    semantic_colors.ok and semantic_colors.count == 1,
    "Tinymist color info should return colors"
)
local color_lines =
    vim.api.nvim_buf_get_lines(semantic_colors.buffer, 0, -1, false)
assert(
    color_lines[2]:find("■ #ff0000", 1, true),
    "color report should render a visible swatch and hex value"
)
local semantic_ns = vim.api.nvim_create_namespace("typst.semantic")
assert(
    #vim.api.nvim_buf_get_extmarks(
            semantic_source_buf,
            semantic_ns,
            0,
            -1,
            {}
        ) > 0,
    "color info should decorate source colors with extmarks"
)

old_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function()
    return {
        {
            name = "tinymist",
            supports_method = function()
                return true
            end,
            request = function(_, method, _, callback)
                if method == "textDocument/codeLens" then
                    callback(nil, {
                        {
                            range = { start = { line = 0, character = 0 } },
                            command = {
                                title = "Export PDF",
                                command = "tinymist.exportPdf",
                            },
                        },
                    })
                    return true, 3
                end
            end,
        },
    }
end
local code_lens = nil
local code_lens_pending = typst.semantic.code_lens({
    open = false,
    bufnr = semantic_source_buf,
    callback = function(result)
        code_lens = result
    end,
})
vim.lsp.get_clients = old_get_clients
assert(
    code_lens_pending and code_lens_pending.pending,
    "Tinymist code lens should return a pending request"
)
assert(
    vim.wait(100, function()
        return code_lens ~= nil
    end),
    "Tinymist code lens should finish asynchronously"
)
assert(
    code_lens.ok and code_lens.count == 1,
    "code_lens should list Tinymist code lenses"
)

local fake_tinymist =
    helpers.python_command(root .. "/tests/fixtures/fake-tinymist-dev.py")
local util = require("typst.core.util")
local default_test = nil
local default_test_run = typst.development.test(
    { executable = fake_tinymist, args = { "--update" }, open = false },
    function(result)
        default_test = result
    end
)
assert(
    default_test_run.ok and default_test_run.pending,
    "default Tinymist test provider should run asynchronously"
)
assert(
    vim.wait(5000, function()
        return default_test ~= nil
    end, 20),
    "default Tinymist test provider did not finish"
)
assert(
    default_test.ok and default_test.provider == "tinymist",
    "default test provider should use tinymist"
)
assert(
    default_test.stdout:find("fake%-tinymist test|%-%-root|", 1, false),
    "default test should invoke tinymist test"
)
assert(
    default_test.stdout:find("%-%-update", 1, false),
    "default test should pass user args"
)

local default_coverage = nil
local coverage_path =
    typst_test_cache_path("tinymist coverage/coverage with spaces.json")
typst.development.coverage({
    executable = fake_tinymist,
    env = {
        TINYMIST_COVERAGE_PATH = coverage_path,
    },
    full = true,
    open = false,
}, function(result)
    default_coverage = result
end)
assert(
    vim.wait(5000, function()
        return default_coverage ~= nil
    end, 20),
    "default Tinymist coverage provider did not finish"
)
assert(
    default_coverage.ok and default_coverage.provider == "tinymist",
    "coverage provider should use tinymist"
)
assert(
    default_coverage.coverage == coverage_path,
    "coverage should report the generated XDG-backed coverage path with spaces"
)
assert(
    vim.fn.filereadable(default_coverage.coverage) == 1,
    "coverage provider should create coverage output"
)
assert(
    default_coverage.stdout:find("%-%-coverage", 1, false)
        and default_coverage.stdout:find("%-%-print%-coverage=full", 1, false),
    "coverage provider should pass Tinymist coverage flags"
)

vim.fn.delete(util.coverage_output_dir(), "rf")
local unreported_coverage = nil
typst.development.coverage({
    executable = {
        "sh",
        "-c",
        "printf 'coverage completed without artifact path\\n'",
        "sh",
    },
    open = false,
}, function(result)
    unreported_coverage = result
end)
assert(
    vim.wait(5000, function()
        return unreported_coverage ~= nil
    end, 20),
    "coverage command without a reported artifact path did not finish"
)
assert(
    unreported_coverage.ok and unreported_coverage.coverage == nil,
    "coverage should not report an uncreated fallback artifact"
)
assert(
    unreported_coverage.coverage_expected
        and util.path_within(
            unreported_coverage.coverage_expected,
            util.coverage_output_dir()
        )
        and util.basename(unreported_coverage.coverage_expected)
            == "coverage.json",
    "coverage should retain the expected XDG fallback for diagnostics"
)
assert(
    vim.fn.filereadable(unreported_coverage.coverage_expected) == 0,
    "unreported coverage fallback should not exist"
)

local fake_crityp =
    helpers.python_command(root .. "/tests/fixtures/fake-crityp.py")
local default_bench = nil
typst.development.bench(
    { executable = fake_crityp, args = { "--warmup", "1" }, open = false },
    function(result)
        default_bench = result
    end
)
assert(
    vim.wait(5000, function()
        return default_bench ~= nil
    end, 20),
    "default crityp bench provider did not finish"
)
assert(
    default_bench.ok and default_bench.provider == "crityp",
    "default bench provider should use crityp"
)
assert(
    default_bench.stdout:find("fake%-crityp", 1, false),
    "default bench should invoke crityp"
)
assert(
    default_bench.stdout:find("%-%-warmup|1", 1, false),
    "default bench should pass user args"
)

local missing_test_provider = typst.development.test({
    notify = false,
    executable = root .. "/does-not-exist-tinymist",
})
assert(
    not missing_test_provider.ok,
    "test without executable should not pretend success"
)
assert(
    missing_test_provider.reason == "missing_executable",
    "test without executable should report missing_executable"
)

assert(
    type(typst_test_artifacts(project).items) == "table",
    "project should keep artifact registry"
)

vim.cmd("qa!")
