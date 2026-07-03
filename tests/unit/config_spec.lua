local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local config = require("typst.config")
local compile_config = require("typst.config.compile")
local typst = require("typst")
local util = require("typst.core.util")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("config-output"),
    compile = {
        extra_args = { "--font-path", root },
    },
})

local generation_before = config.generation()
config.setup(config.get())
assert(
    config.generation() == generation_before + 1,
    "config generation should increment after successful setup"
)
local before = config.get()
assert(
    config.unsafe_get() ~= before,
    "get should return a read-only view instead of the live mutable table"
)
local ok_set_root, err_set_root = pcall(function()
    before.output_dir = "mutated"
end)
assert(not ok_set_root, "config.get should reject top-level mutation")
assert(
    tostring(err_set_root):match("read%-only"),
    "config.get top-level mutation error should mention read-only state"
)
assert(
    tostring(err_set_root):match("config%.get%(%)"),
    "config.get mutation error should identify the read-only API"
)
assert(
    not tostring(err_set_root):match(
        "unsafe_get%(%) for internal mutable access"
    ),
    "config.get mutation error should not recommend unsafe mutation"
)
local ok_set_nested, err_set_nested = pcall(function()
    before.compile.extra_args[1] = "--mutated"
end)
assert(not ok_set_nested, "config.get should reject nested mutation")
assert(
    tostring(err_set_nested):match("read%-only"),
    "config.get nested mutation error should mention read-only state"
)
config.unsafe_get().compile.extra_args[1] = "--font-path"
assert(
    config.get().compile.extra_args[1] == "--font-path",
    "unsafe_get should expose the internal live mutable table"
)
local snapshot = config.snapshot()
snapshot.compile.extra_args[1] = "--mutated"
assert(
    config.get().compile.extra_args[1] == "--font-path",
    "config snapshot mutation should not affect the active config"
)
assert(
    config.snapshot() ~= config.get(),
    "config snapshot should return a fresh table"
)
local combining_e = "e\204\129"
local default_config = config.defaults()
assert(
    default_config.output_dir == util.output_dir(),
    "default output_dir should use the XDG/Neovim cache path"
)
assert(
    default_config.compile.fragments.output_dir == util.fragments_output_dir(),
    "default fragment output_dir should use the XDG/Neovim cache path"
)
assert(
    default_config.compile.fragments.source_dir == nil,
    "default fragment source_dir should use stdin for the built-in compiler"
)
assert(
    default_config.render.output_dir == util.render_output_dir(),
    "default render output_dir should use the XDG/Neovim cache path"
)
assert(
    default_config.render.source_dir == util.render_source_dir(),
    "default render source_dir should use the XDG/Neovim cache path"
)
assert(
    default_config.render.source_mode == "stdin",
    "default render source_mode should avoid wrapper source files"
)
assert(type(default_config.api) == "table", "api config should be a table")
assert(
    default_config.integrations.tinymist.lsp == "auto",
    "Tinymist Neovim LSP integration should default to auto mode"
)
assert(
    default_config.integrations.semantic.provider == "tinymist",
    "semantic provider integration should default to Tinymist"
)
assert(
    default_config.integrations.tinymist.path == "tinymist",
    "Tinymist path should default to the tinymist executable"
)
assert(
    default_config.compile.watch_output == "auto",
    "watch output mode should default to auto"
)
assert(
    default_config.compile.watch_output_wait_ms == 1500,
    "watch output wait timeout should default to 1500ms"
)
assert(
    default_config.syntax.package_semantic_proof == "auto",
    "package syntax semantic proof should default to auto"
)
assert(
    default_config.bibliography.completion == "auto",
    "bibliography completion should default to auto"
)
assert(
    default_config.project.import_scan_max_entries == 2000,
    "project import scan entry cap should default to 2000"
)
assert(
    vim.tbl_contains(default_config.project.import_scan_skip_dirs, "build"),
    "project import scan should skip common generated directories by default"
)
assert(
    default_config.project.index.max_file_bytes == 1024 * 1024,
    "project index static file cap should default to 1MiB"
)
assert(
    default_config.project.index.large_file_policy == "skip",
    "project index large-file policy should default to skip"
)
assert(
    default_config.preview.browser.max_artifact_bytes == 32 * 1024 * 1024,
    "native browser artifact cap should default to 32MiB"
)
assert(
    default_config.preview.browser.allow_remote == false,
    "native browser preview should refuse remote binds by default"
)
assert(
    default_config.preview.browser.token == "auto",
    "native browser remote route tokens should default to auto"
)
assert(
    vim.tbl_contains(default_config.bibliography.attachment_fields, "pdf"),
    "bibliography attachment discovery should default to PDF fields"
)
assert(
    vim.tbl_contains(default_config.bibliography.attachment_paths, "{key}.pdf"),
    "bibliography attachment discovery should default to key-based paths"
)

local invalid_configs = {
    {
        opts = { api = false },
        message = "api must be a table",
    },
    {
        opts = { executable = {} },
        message = "executable must not be an empty list",
    },
    {
        opts = { executable = { "typst", 42 } },
        message = "executable%[2%]",
    },
    {
        opts = { metadata_version = 42 },
        message = "metadata_version",
    },
    {
        opts = { output_dir = 42 },
        message = "output_dir",
    },
    {
        opts = { output_name = "" },
        message = "output_name",
    },
    {
        opts = { root_markers = { ".git", 42 } },
        message = "root_markers%[2%]",
    },
    {
        opts = { main = { [root] = 42 } },
        message = "main%[",
    },
    {
        opts = { project = false },
        message = "project must be a table",
    },
    {
        opts = { project = { import_scan = "yes" } },
        message = "project.import_scan",
    },
    {
        opts = { project = { persist_main = "yes" } },
        message = "project.persist_main",
    },
    {
        opts = { project = { import_scan_max_files = 0 } },
        message = "project.import_scan_max_files",
    },
    {
        opts = { project = { import_scan_max_depth = -1 } },
        message = "project.import_scan_max_depth",
    },
    {
        opts = { project = { import_scan_max_entries = 0 } },
        message = "project.import_scan_max_entries",
    },
    {
        opts = { project = { import_scan_skip_dirs = false } },
        message = "project.import_scan_skip_dirs",
    },
    {
        opts = { project = { import_scan_skip_dirs = { "build", "" } } },
        message = "project.import_scan_skip_dirs%[2%]",
    },
    {
        opts = { project = { import_scan_skip_dirs = { "build/" } } },
        message = "directory name, not a path",
    },
    {
        opts = { project = { import_scan_skip_dirs = { "foo\\build" } } },
        message = "directory name, not a path",
    },
    {
        opts = { project = { index = false } },
        message = "project.index",
    },
    {
        opts = { project = { index = { fs_watchers = "many" } } },
        message = "project.index.fs_watchers",
    },
    {
        opts = { project = { index = { max_file_bytes = -1 } } },
        message = "project.index.max_file_bytes",
    },
    {
        opts = { project = { index = { large_file_policy = "summary" } } },
        message = "project.index.large_file_policy",
    },
    {
        opts = { integrations = false },
        message = "integrations must be a table",
    },
    {
        opts = { integrations = { tinymist = false } },
        message = "integrations.tinymist must be a table",
    },
    {
        opts = { integrations = { semantic = false } },
        message = "integrations.semantic must be a table",
    },
    {
        opts = { integrations = { semantic = { provider = "" } } },
        message = "integrations.semantic.provider",
    },
    {
        opts = { integrations = { tinymist = { lsp = "coc" } } },
        message = "integrations.tinymist.lsp",
    },
    {
        opts = { integrations = { tinymist = { cmd = {} } } },
        message = "integrations.tinymist.cmd",
    },
    {
        opts = { integrations = { tinymist = { path = "" } } },
        message = "integrations.tinymist.path",
    },
    {
        opts = { integrations = { tinymist = { settings = "yes" } } },
        message = "integrations.tinymist.settings",
    },
    {
        opts = { integrations = { tinymist = { init_options = "yes" } } },
        message = "integrations.tinymist.init_options",
    },
    {
        opts = { integrations = { tinymist = { capabilities = "yes" } } },
        message = "integrations.tinymist.capabilities",
    },
    {
        opts = { integrations = { tinymist = { on_attach = "yes" } } },
        message = "integrations.tinymist.on_attach",
    },
    {
        opts = { compile = { extra_args = { "--jobs", 2 } } },
        message = "compile.extra_args%[2%]",
    },
    {
        opts = { compile = { watch_output = "yaml" } },
        message = "compile.watch_output",
    },
    {
        opts = { compile = { watch_output_wait_ms = 60001 } },
        message = "compile.watch_output_wait_ms",
    },
    {
        opts = { compile = { watch_structured_args = { "--format", 1 } } },
        message = "compile.watch_structured_args%[2%]",
    },
    {
        opts = {
            compile = { profiles = { draft = { watch_output = "yaml" } } },
        },
        message = "compile.profiles.draft.watch_output",
    },
    {
        opts = {
            compile = {
                profiles = { draft = { watch_output_wait_ms = 60001 } },
            },
        },
        message = "compile.profiles.draft.watch_output_wait_ms",
    },
    {
        opts = { compile = { generic = false } },
        message = "compile.generic must be a table",
    },
    {
        opts = { compile = { generic = { compile = {} } } },
        message = "compile.generic.compile must not be an empty list",
    },
    {
        opts = { compile = { task = { cwd = 42 } } },
        message = "compile.task.cwd",
    },
    {
        opts = { compile = { profiles = { draft = { output_name = "" } } } },
        message = "compile.profiles.draft.output_name",
    },
    {
        opts = { compile = { profiles = { draft = { provider = "typst" } } } },
        message = "compile.profiles.draft.provider is not supported",
    },
    {
        opts = { compile = { fragments = false } },
        message = "compile.fragments",
    },
    {
        opts = { compile = { fragments = { default = "missing" } } },
        message = "compile.fragments.default",
    },
    {
        opts = { compile = { fragments = { source_dir = false } } },
        message = "compile.fragments.source_dir",
    },
    {
        opts = {
            compile = {
                fragments = { templates = { custom = { prefix = 42 } } },
            },
        },
        message = "compile.fragments.templates.custom.prefix",
    },
    {
        opts = {
            compile = {
                fragments = { templates = { custom = { source_dir = false } } },
            },
        },
        message = "compile.fragments.templates.custom.source_dir",
    },
    {
        opts = {
            compile = {
                fragments = { templates = { custom = "no body placeholder" } },
            },
        },
        message = "compile.fragments.templates.custom string template",
    },
    {
        opts = { compile = { provider_timeout_ms = -1 } },
        message = "compile.provider_timeout_ms",
    },
    {
        opts = { exports = { timeout_ms = -1 } },
        message = "exports.timeout_ms",
    },
    {
        opts = { exports = { profiles = { text = { command = {} } } } },
        message = "exports.profiles.text.command must not be an empty list",
    },
    {
        opts = { exports = { profiles = { text = { stdout = "yes" } } } },
        message = "exports.profiles.text.stdout",
    },
    {
        opts = {
            exports = {
                profiles = {
                    text = {
                        command = "writer",
                        provider = "writer",
                    },
                },
            },
        },
        message = "exports.profiles.text cannot set both command and provider",
    },
    {
        opts = { exports = { profiles = { text = { inputs = { [1] = 42 } } } } },
        message = "exports.profiles.text.inputs%[1%]",
    },
    {
        opts = {
            exports = {
                profiles = {
                    text = {
                        inputs = {
                            good = {},
                        },
                    },
                },
            },
        },
        message = "exports.profiles.text.inputs.good",
    },
    {
        opts = { render = false },
        message = "render must be a table",
    },
    {
        opts = { render = { output_format = 42 } },
        message = "render.output_format",
    },
    {
        opts = { render = { output_dir = false } },
        message = "render.output_dir",
    },
    {
        opts = { render = { source_dir = false } },
        message = "render.source_dir",
    },
    {
        opts = { render = { source_mode = "buffer" } },
        message = "render.source_mode",
    },
    {
        opts = { render = { timeout_ms = -1 } },
        message = "render.timeout_ms",
    },
    {
        opts = { render = { cache = "yes" } },
        message = "render.cache",
    },
    {
        opts = { render = { cache = { max_entries = -1 } } },
        message = "render.cache.max_entries",
    },
    {
        opts = { render = { max_inline_image_bytes = -1 } },
        message = "render.max_inline_image_bytes",
    },
    {
        opts = { render = { open = "yes" } },
        message = "render.open",
    },
    {
        opts = { completion = { universe_index_paths = "universe.json" } },
        message = "completion.universe_index_paths",
    },
    {
        opts = { diagnostics = { enabled = "yes" } },
        message = "diagnostics.enabled",
    },
    {
        opts = { diagnostics = { use_quickfix = "yes" } },
        message = "diagnostics.use_quickfix",
    },
    {
        opts = { diagnostics = { list = "buffer" } },
        message = "diagnostics.list",
    },
    {
        opts = { diagnostics = { fonts = "yes" } },
        message = "diagnostics.fonts",
    },
    {
        opts = { diagnostics = { font_scan_timeout_ms = -1 } },
        message = "diagnostics.font_scan_timeout_ms",
    },
    {
        opts = { bibliography = false },
        message = "bibliography must be a table",
    },
    {
        opts = { bibliography = { attachment_fields = "pdf" } },
        message = "bibliography.attachment_fields",
    },
    {
        opts = { bibliography = { attachment_paths = { 42 } } },
        message = "bibliography.attachment_paths%[1%]",
    },
    {
        opts = { bibliography = { completion = "maybe" } },
        message = "bibliography.completion",
    },
    {
        opts = { format = false },
        message = "format must be a table",
    },
    {
        opts = { format = { provider = "unknown" } },
        message = "format.provider",
    },
    {
        opts = { format = { command = {} } },
        message = "format.command must not be an empty list",
    },
    {
        opts = { format = { extra_args = { "--line-width", 80 } } },
        message = "format.extra_args%[2%]",
    },
    {
        opts = { format = { prose_width = 0 } },
        message = "format.prose_width",
    },
    {
        opts = { lint = false },
        message = "lint must be a table",
    },
    {
        opts = { lint = { provider = "unknown" } },
        message = "lint.provider",
    },
    {
        opts = { lint = { command = { "checker", false } } },
        message = "lint.command%[2%]",
    },
    {
        opts = { lint = { timeout_ms = -1 } },
        message = "lint.timeout_ms",
    },
    {
        opts = { grammar = false },
        message = "grammar must be a table",
    },
    {
        opts = { grammar = { provider = "unknown" } },
        message = "grammar.provider",
    },
    {
        opts = { grammar = { command = {} } },
        message = "grammar.command must not be an empty list",
    },
    {
        opts = { grammar = { extra_args = { "--format", 42 } } },
        message = "grammar.extra_args%[2%]",
    },
    {
        opts = { grammar = { timeout_ms = -1 } },
        message = "grammar.timeout_ms",
    },
    {
        opts = { grammar = { stdin = "yes" } },
        message = "grammar.stdin",
    },
    {
        opts = { grammar = { file_arg = "yes" } },
        message = "grammar.file_arg",
    },
    {
        opts = { viewer = false },
        message = "viewer must be a table",
    },
    {
        opts = { viewer = { args = { "--reuse-instance", 42 } } },
        message = "viewer.args%[2%]",
    },
    {
        opts = { viewer = { open = {} } },
        message = "viewer.open must not be an empty list",
    },
    {
        opts = { viewer = { open = { "viewer", false } } },
        message = "viewer.open%[2%]",
    },
    {
        opts = { viewer = { reload = "reload" } },
        message = "viewer.reload",
    },
    {
        opts = { viewer = { provider = "" } },
        message = "viewer.provider",
    },
    {
        opts = { viewer = { provider = "missing" } },
        message = "viewer.provider",
    },
    {
        opts = { viewer = { providers = false } },
        message = "viewer.providers must be a table",
    },
    {
        opts = { viewer = { providers = { zathura = { args = { 42 } } } } },
        message = "viewer.providers.zathura.args%[1%]",
    },
    {
        opts = { viewer = { providers = { zathura = { reload = "reload" } } } },
        message = "viewer.providers.zathura.reload",
    },
    {
        opts = {
            viewer = { providers = { zathura = { inverse_args = { 42 } } } },
        },
        message = "viewer.providers.zathura.inverse_args%[1%]",
    },
    {
        opts = { viewer = { inverse_args = { 42 } } },
        message = "viewer.inverse_args%[1%]",
    },
    {
        opts = { viewer = { capabilities = { source_maps = "yes" } } },
        message = "viewer.capabilities",
    },
    {
        opts = {
            viewer = {
                providers = { zathura = { capabilities = { forward = "yes" } } },
            },
        },
        message = "viewer.providers.zathura.capabilities",
    },
    {
        opts = { preview = false },
        message = "preview must be a table",
    },
    {
        opts = { preview = { provider = "external" } },
        message = "preview.provider",
    },
    {
        opts = { preview = { native = "websocket" } },
        message = "preview.native",
    },
    {
        opts = { preview = { export = false } },
        message = "preview.export",
    },
    {
        opts = { preview = { export = { mode = "tinymist" } } },
        message = "preview.export.mode",
    },
    {
        opts = { preview = { export = { extra_args = { 42 } } } },
        message = "preview.export.extra_args%[1%]",
    },
    {
        opts = { preview = { export = { provider = "" } } },
        message = "preview.export.provider",
    },
    {
        opts = { preview = { cache = false } },
        message = "preview.cache",
    },
    {
        opts = { preview = { cache = { max_entries = -1 } } },
        message = "preview.cache.max_entries",
    },
    {
        opts = { preview = { forward = "forward" } },
        message = "preview.forward",
    },
    {
        opts = { preview = { refresh = "refresh" } },
        message = "preview.refresh",
    },
    {
        opts = { preview = { reuse = "yes" } },
        message = "preview.reuse",
    },
    {
        opts = { preview = { capabilities = { inverse = "yes" } } },
        message = "preview.capabilities",
    },
    {
        opts = { preview = { source_maps = false } },
        message = "preview.source_maps",
    },
    {
        opts = { preview = { source_maps = { provider = "" } } },
        message = "preview.source_maps.provider",
    },
    {
        opts = { preview = { source_maps = { forward = "forward" } } },
        message = "preview.source_maps.forward",
    },
    {
        opts = {
            preview = { source_maps = { capabilities = { inverse = "yes" } } },
        },
        message = "preview.source_maps.capabilities",
    },
    {
        opts = { preview = { browser = false } },
        message = "preview.browser",
    },
    {
        opts = { preview = { browser = { port = -1 } } },
        message = "preview.browser.port",
    },
    {
        opts = { preview = { browser = { server = "yes" } } },
        message = "preview.browser.server",
    },
    {
        opts = { preview = { browser = { allow_remote = "yes" } } },
        message = "preview.browser.allow_remote",
    },
    {
        opts = { preview = { browser = { token = "" } } },
        message = "preview.browser.token",
    },
    {
        opts = { preview = { browser = { output_dir = "" } } },
        message = "preview.browser.output_dir",
    },
    {
        opts = { preview = { browser = { max_artifact_bytes = -1 } } },
        message = "preview.browser.max_artifact_bytes",
    },
    {
        opts = { preview = { browser = { refresh_ms = -1 } } },
        message = "preview.browser.refresh_ms",
    },
    {
        opts = { preview = { browser = { reload_throttle_ms = -1 } } },
        message = "preview.browser.reload_throttle_ms",
    },
    {
        opts = { preview = { browser = { performance = "turbo" } } },
        message = "preview.browser.performance",
    },
    {
        opts = { preview = { browser = { app = 42 } } },
        message = "preview.browser.app",
    },
    {
        opts = { preview = { browser = { commands = "open" } } },
        message = "preview.browser.commands",
    },
    {
        opts = {
            preview = { browser = { commands = { { "open" }, { 42 } } } },
        },
        message = "preview.browser.commands%[2%]",
    },
    {
        opts = { preview = { browser = { open = "open" } } },
        message = "preview.browser.open",
    },
    {
        opts = { preview = { browser = { style = false } } },
        message = "preview.browser.style",
    },
    {
        opts = { preview = { browser = { style = { css = false } } } },
        message = "preview.browser.style.css",
    },
    {
        opts = { preview = { browser = { style = { css_path = "" } } } },
        message = "preview.browser.style.css_path",
    },
    {
        opts = {
            preview = {
                browser = {
                    style = {
                        variables = {
                            ["bad name"] = "#fff",
                        },
                    },
                },
            },
        },
        message = "preview.browser.style.variables",
    },
    {
        opts = { preview = { browser = { export = false } } },
        message = "preview.browser.export",
    },
    {
        opts = { preview = { browser = { export = { mode = "tinymist" } } } },
        message = "preview.browser.export.mode",
    },
    {
        opts = {
            preview = { browser = { export = { output_format = "" } } },
        },
        message = "preview.browser.export.output_format",
    },
    {
        opts = { syntax = false },
        message = "syntax must be a table",
    },
    {
        opts = { syntax = { package_extensions = "yes" } },
        message = "syntax.package_extensions",
    },
    {
        opts = { syntax = { package_semantic_proof = "maybe" } },
        message = "syntax.package_semantic_proof",
    },
    {
        opts = { syntax = { package_highlight_group = "" } },
        message = "syntax.package_highlight_group",
    },
    {
        opts = { syntax = { package_highlight_priority = -1 } },
        message = "syntax.package_highlight_priority",
    },
    {
        opts = { syntax = { packages = false } },
        message = "syntax.packages must be a table",
    },
    {
        opts = { syntax = { packages = { ["@preview/bad"] = false } } },
        message = "syntax.packages.@preview/bad must be a table",
    },
    {
        opts = {
            syntax = { packages = { ["@preview/bad"] = { members = { 42 } } } },
        },
        message = "syntax.packages.@preview/bad.members%[1%]",
    },
    {
        opts = { conceal = false },
        message = "conceal must be a table",
    },
    {
        opts = { conceal = { enabled = "yes" } },
        message = "conceal.enabled",
    },
    {
        opts = { conceal = { categories = { math_symbols = "yes" } } },
        message = "conceal.categories.math_symbols",
    },
    {
        opts = { conceal = { categories = { references = true } } },
        message = "conceal.categories.references.*reference_markers",
    },
    {
        opts = { conceal = { categories = { citations = true } } },
        message = "conceal.categories.citations.*reference_markers",
    },
    {
        opts = { conceal = { categories = { typo = true } } },
        message = "unknown conceal category.*conceal.categories.typo",
    },
    {
        opts = {
            conceal = {
                categories = { function_wrappers = { strong = "yes" } },
            },
        },
        message = "conceal.categories.function_wrappers.strong",
    },
    {
        opts = {
            conceal = {
                categories = { function_wrappers = { unknown = true } },
            },
        },
        message = "unknown function wrapper conceal category.*function_wrappers.unknown",
    },
    {
        opts = { conceal = { custom = false } },
        message = "conceal.custom must be a table",
    },
    {
        opts = { conceal = { custom = { math = { [42] = "x" } } } },
        message = "conceal.custom.math keys",
    },
    {
        opts = { conceal = { custom = { math = { custom = 42 } } } },
        message = "conceal.custom.math.custom",
    },
    {
        opts = { conceal = { custom = { math = { custom = "xx" } } } },
        message = "conceal.custom.math.custom.*exactly one character",
    },
    {
        opts = { conceal = { custom = { math = { custom = combining_e } } } },
        message = "conceal.custom.math.custom.*exactly one character",
    },
    {
        opts = { conceal = { custom = { math = { custom = "😇" } } } },
        message = "conceal.custom.math.custom.*max_display_width",
    },
    {
        opts = { conceal = { safety = { max_display_width = -1 } } },
        message = "conceal.safety.max_display_width",
    },
    {
        opts = { completion = false },
        message = "completion must be a table",
    },
    {
        opts = { completion = { include_packages = "yes" } },
        message = "completion.include_packages",
    },
    {
        opts = { completion = { include_paths = "yes" } },
        message = "completion.include_paths",
    },
    {
        opts = { completion = { include_csl_styles = "yes" } },
        message = "completion.include_csl_styles",
    },
    {
        opts = { completion = { include_raw_languages = "yes" } },
        message = "completion.include_raw_languages",
    },
    {
        opts = { completion = { include_colors = "yes" } },
        message = "completion.include_colors",
    },
    {
        opts = { completion = { include_fonts = "yes" } },
        message = "completion.include_fonts",
    },
    {
        opts = { completion = { csl_styles = { "apa", 42 } } },
        message = "completion.csl_styles%[2%]",
    },
    {
        opts = { completion = { raw_languages = { "valid", 42 } } },
        message = "completion.raw_languages%[2%]",
    },
    {
        opts = { completion = { color_names = { "valid", 42 } } },
        message = "completion.color_names%[2%]",
    },
    {
        opts = { completion = { font_families = { "valid", 42 } } },
        message = "completion.font_families%[2%]",
    },
    {
        opts = { completion = { font_scan_timeout_ms = -1 } },
        message = "completion.font_scan_timeout_ms",
    },
    {
        opts = { completion = { path_scan_max = -1 } },
        message = "completion.path_scan_max",
    },
    {
        opts = { completion = { path_scan_cache_ms = -1 } },
        message = "completion.path_scan_cache_ms",
    },
    {
        opts = { completion = { csl_scan_max = -1 } },
        message = "completion.csl_scan_max",
    },
    {
        opts = { completion = { scan_cache_ttl_ms = -1 } },
        message = "completion.scan_cache_ttl_ms",
    },
    {
        opts = { completion = { package_scan_max = -1 } },
        message = "completion.package_scan_max",
    },
    {
        opts = { completion = { package_cache_ttl_ms = -1 } },
        message = "completion.package_cache_ttl_ms",
    },
    {
        opts = { completion = { package_cache_prewarm = "yes" } },
        message = "completion.package_cache_prewarm",
    },
    {
        opts = { toc = false },
        message = "toc must be a table",
    },
    {
        opts = { toc = { mode = "floating" } },
        message = "toc.mode",
    },
    {
        opts = { toc = { position = "middle" } },
        message = "toc.position",
    },
    {
        opts = { toc = { width = 0 } },
        message = "toc.width",
    },
    {
        opts = { toc = { height = 0 } },
        message = "toc.height",
    },
    {
        opts = { toc = { auto_close = "yes" } },
        message = "toc.auto_close",
    },
    {
        opts = { toc = { follow_cursor = "yes" } },
        message = "toc.follow_cursor",
    },
    {
        opts = { toc = { highlight_current = "yes" } },
        message = "toc.highlight_current",
    },
    {
        opts = { toc = { auto_refresh = "yes" } },
        message = "toc.auto_refresh",
    },
    {
        opts = { toc = { follow_delay_ms = -1 } },
        message = "toc.follow_delay_ms",
    },
    {
        opts = { toc = { refresh_delay_ms = -1 } },
        message = "toc.refresh_delay_ms",
    },
    {
        opts = { toc = { visible_layers = false } },
        message = "toc.visible_layers",
    },
    {
        opts = { toc = { visible_layers = { label = "yes" } } },
        message = "toc.visible_layers.label",
    },
    {
        opts = { toc = { mappings = false } },
        message = "toc.mappings",
    },
    {
        opts = { toc = { mappings = { enabled = "yes" } } },
        message = "toc.mappings.enabled",
    },
    {
        opts = { toc = { mappings = { refresh = 42 } } },
        message = "toc.mappings.refresh",
    },
    {
        opts = { toc = { mappings = { preview = 42 } } },
        message = "toc.mappings.preview",
    },
    {
        opts = { toc = { mappings = { toggle = 42 } } },
        message = "toc.mappings.toggle",
    },
    {
        opts = { toc = { mappings = { toggle_layer = 42 } } },
        message = "toc.mappings.toggle_layer",
    },
    {
        opts = { toc = { mappings = { filter = 42 } } },
        message = "toc.mappings.filter",
    },
    {
        opts = { toc = { mappings = { clear_filter = 42 } } },
        message = "toc.mappings.clear_filter",
    },
    {
        opts = { picker = false },
        message = "picker must be a table",
    },
    {
        opts = { picker = { provider = "unknown" } },
        message = "picker.provider",
    },
    {
        opts = { picker = { kinds = { "labels", 42 } } },
        message = "picker.kinds%[2%]",
    },
    {
        opts = { picker = { custom = "not-callback" } },
        message = "picker.custom",
    },
    {
        opts = { picker = { telescope = false } },
        message = "picker.telescope",
    },
    {
        opts = { picker = { fzf_vim = false } },
        message = "picker.fzf_vim",
    },
    {
        opts = { indent = false },
        message = "indent must be a table",
    },
    {
        opts = { indent = { enabled = "yes" } },
        message = "indent.enabled",
    },
    {
        opts = { indent = { formatexpr = "yes" } },
        message = "indent.formatexpr",
    },
    {
        opts = { imaps = false },
        message = "imaps must be a table",
    },
    {
        opts = { imaps = { enabled = "yes" } },
        message = "imaps.enabled",
    },
    {
        opts = { imaps = { mappings = { { lhs = ";x", rhs = 42 } } } },
        message = "imaps.mappings%[1%].rhs",
    },
    {
        opts = { matchparen = { enabled = "yes" } },
        message = "matchparen.enabled",
    },
    {
        opts = { mappings = { enabled = "yes" } },
        message = "mappings.enabled",
    },
    {
        opts = { mappings = { match = 42 } },
        message = "mappings.match",
    },
    {
        opts = { mappings = { hover = 42 } },
        message = "mappings.hover",
    },
    {
        opts = { mappings = { repeat_transform = 42 } },
        message = "mappings.repeat_transform",
    },
    {
        opts = { mappings = { commands = false } },
        message = "mappings.commands",
    },
    {
        opts = { mappings = { commands = { watch = 42 } } },
        message = "mappings.commands.watch",
    },
    {
        opts = { mappings = { insert = false } },
        message = "mappings.insert",
    },
    {
        opts = { mappings = { insert = { math = 42 } } },
        message = "mappings.insert.math",
    },
    {
        opts = { docs = { provider_chain = { "tinymist", "stdlib" } } },
        message = "docs configuration was removed",
    },
    {
        opts = { log = { max_entries = -1 } },
        message = "log.max_entries",
    },
}

for _, case in ipairs(invalid_configs) do
    local ok, err = pcall(function()
        typst.setup(case.opts)
    end)

    assert(not ok, "invalid config should fail validation")
    assert(tostring(err):match(case.message), tostring(err))
    assert(
        config.get() == before,
        "failed setup should preserve the previous active config"
    )
end

local zero_wait_ok, zero_wait_err = pcall(function()
    typst.setup({
        root = root,
        compile = {
            watch_output_wait_ms = 0,
        },
    })
end)
assert(zero_wait_ok, zero_wait_err)
assert(
    config.get().compile.watch_output_wait_ms == 0,
    "watch output wait timeout should accept 0 to disable waiting"
)

local profile_overlay_ok, profile_overlay_err = pcall(function()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("profile-base-output"),
        output_name = "base",
        output_format = "pdf",
        compile = {
            extra_args = { "--input", "base=true" },
            watch_output = "auto",
            watch_output_wait_ms = 1500,
            watch_structured_args = { "--base-watch" },
            deps = true,
            open = false,
            typst_open = false,
            profiles = {
                all = {
                    output_format = "svg",
                    output_name = "profile",
                    output_dir = typst_test_cache_path("profile-output"),
                    extra_args = { "--input", "profile=true" },
                    watch_output = "structured",
                    watch_output_wait_ms = 2500,
                    watch_structured_args = { "--format", "json" },
                    deps = false,
                    open = true,
                    typst_open = true,
                },
            },
        },
    })
end)
assert(profile_overlay_ok, profile_overlay_err)

local run_config = config.for_run("all")
local profile_expectations = {
    output_format = function(run)
        return run.output_format == "svg"
    end,
    output_name = function(run)
        return run.output_name == "profile"
    end,
    output_dir = function(run)
        return run.output_dir:match("profile%-output") ~= nil
    end,
    extra_args = function(run)
        return run.compile.extra_args[2] == "profile=true"
    end,
    watch_output = function(run)
        return run.compile.watch_output == "structured"
    end,
    watch_output_wait_ms = function(run)
        return run.compile.watch_output_wait_ms == 2500
    end,
    watch_structured_args = function(run)
        return run.compile.watch_structured_args[2] == "json"
    end,
    deps = function(run)
        return run.compile.deps == false
    end,
    open = function(run)
        return run.compile.open == true
    end,
    typst_open = function(run)
        return run.compile.typst_open == true
    end,
}

for _, key in ipairs(compile_config.profile_override_keys()) do
    assert(
        profile_expectations[key],
        ("profile override key %s should have overlay coverage"):format(key)
    )
    assert(
        profile_expectations[key](run_config),
        ("compile profile field %s should overlay run config"):format(key)
    )
end

run_config.compile.extra_args[2] = "mutated=true"
run_config.compile.watch_structured_args[2] = "text"
local run_config_again = config.for_run("all")
assert(
    run_config_again.compile.extra_args[2] == "profile=true",
    "profile extra_args overlay should be deep-copied"
)
assert(
    run_config_again.compile.watch_structured_args[2] == "json",
    "profile watch_structured_args overlay should be deep-copied"
)

local ok, err = pcall(function()
    typst.setup({
        root = root,
        executable = { "typst", "--ignore-system-fonts" },
        metadata_version = "0.15.0",
        output_dir = "",
        root_markers = {},
        project = {
            import_scan = false,
            import_scan_max_files = 25,
            import_scan_max_depth = 1,
            import_scan_max_entries = 100,
            import_scan_skip_dirs = { "heavy", "generated" },
            persist_main = false,
            index = {
                fs_watchers = 64,
                max_file_bytes = 512,
                large_file_policy = "headings-only",
            },
        },
        compile = {
            generic = {
                compile = { "make", "{output}" },
                cwd = "{root}",
            },
            task = {
                compile = "just",
                output = function()
                    return typst_test_cache_path("task.pdf")
                end,
            },
            fragments = {
                default = "custom",
                source_dir = typst_test_cache_path("custom-fragment-sources"),
                templates = {
                    custom = {
                        prefix = '#let fragment-title = "selected"\n',
                        suffix = "\n",
                        source_dir = typst_test_cache_path(
                            "custom-template-sources"
                        ),
                    },
                    inline = "{body}\n",
                },
            },
            profiles = {
                draft = {
                    extra_args = { "--font-path", root },
                },
            },
        },
        mappings = {
            enabled = false,
            hover = "K",
            insert = {
                math = "<M-m>",
            },
        },
        diagnostics = {
            list = "loclist",
            fonts = false,
            font_scan_timeout_ms = 25,
        },
        conceal = {
            categories = {
                lists = true,
                raw_blocks = true,
                raw_block_languages = true,
                reference_markers = true,
                function_wrappers = {
                    emph = false,
                },
            },
            custom = {
                math = {
                    customop = "*",
                },
            },
        },
        indent = {
            enabled = false,
            formatexpr = false,
        },
        imaps = {
            enabled = true,
            mappings = {
                {
                    lhs = ";u",
                    rhs = function()
                        return "unit"
                    end,
                    modes = { "math" },
                    description = "unit test",
                },
            },
        },
        matchparen = {
            enabled = false,
        },
        viewer = {
            provider = "zathura",
            open = { "viewer", "--reuse-instance" },
            reload = function()
                return true
            end,
            inverse = "viewer-inverse",
            inverse_args = { "--source", "{source}", "{line}", "{column}" },
            capabilities = {
                source_maps = true,
            },
            providers = {
                zathura = {
                    open = "zathura",
                    reload = function()
                        return true
                    end,
                    args = { "--reuse-instance", "{output}" },
                    inverse = "zathura-inverse",
                    inverse_args = { "{source}" },
                    capabilities = {
                        forward = false,
                        inverse = false,
                    },
                },
            },
        },
        render = {
            source_mode = "file",
            source_dir = typst_test_cache_path("custom-render-sources"),
            cache = {
                enabled = true,
                max_entries = 2,
                max_bytes = 1024,
                ttl_ms = 250,
            },
            max_inline_image_bytes = 512,
        },
        format = {
            provider = function()
                return { ok = true, text = "" }
            end,
            prose_width = 64,
        },
        lint = {
            provider = {
                name = "custom-lint",
                lint = function()
                    return { ok = true, diagnostics = 0 }
                end,
            },
        },
        log = {
            max_entries = 0,
        },
        preview = {
            provider = "typst-preview.nvim",
            native = "browser",
            reuse = false,
            cache = {
                enabled = true,
                max_entries = 3,
                max_bytes = 2048,
                ttl_ms = 500,
            },
            export = {
                mode = "compile",
                profile = "draft",
                provider = "preview-export-provider",
                output_format = "pdf",
                output_name = "preview",
                output_dir = typst_test_cache_path("preview-export"),
                extra_args = { "--font-path", "fonts" },
            },
            browser = {
                host = "127.0.0.1",
                allow_remote = true,
                token = "test-preview-token",
                port = 12345,
                server = false,
                output_dir = typst_test_cache_path("browser-preview"),
                max_artifact_bytes = 4096,
                refresh_ms = 250,
                reload_throttle_ms = 500,
                performance = "fast",
                app = "chrome",
                commands = {
                    { "test-browser-opener", "{url}" },
                    { "xdg-open" },
                },
                open = function()
                    return true
                end,
                style = {
                    variables = {
                        bg = "#101010",
                        ["--custom-preview-accent"] = "#ffcc00",
                    },
                    css = "body { letter-spacing: 0; }",
                    css_path = typst_test_config_path("browser-preview.css"),
                },
                export = {
                    mode = "compile",
                    output_format = "svg",
                    extra_args = { "--features", "html" },
                },
            },
            refresh = function()
                return true
            end,
            capabilities = {
                inverse = true,
                source_maps = true,
            },
            source_maps = {
                provider = "preview-source-map-provider",
                forward = function()
                    return true
                end,
                inverse = function()
                    return true
                end,
                capabilities = {
                    source_maps = true,
                },
            },
        },
        toc = {
            mode = "quickfix",
            position = "left",
            width = 40,
            height = 10,
            auto_close = true,
            follow_cursor = false,
            highlight_current = false,
            auto_refresh = false,
            follow_delay_ms = 15,
            refresh_delay_ms = 25,
            visible_layers = {
                todo = false,
            },
            mappings = {
                enabled = true,
                jump = "o",
                preview = "p",
                close = "x",
                refresh = "R",
                toggle = "z",
                toggle_layer = "l",
                filter = "f",
                clear_filter = "F",
            },
        },
        picker = {
            provider = "fzf_vim",
            fzf_vim = {
                down = "40%",
            },
        },
        completion = {
            include_packages = true,
            include_templates = false,
            universe_index_paths = {
                root .. "/tests/fixtures/universe-index.json",
            },
            include_paths = true,
            include_csl_styles = true,
            csl_styles = { "custom-style" },
            include_raw_languages = true,
            raw_languages = { "custom-raw-lang" },
            include_colors = true,
            color_names = { "brand-primary" },
            include_fonts = true,
            font_families = { "Unit Test Serif" },
            font_scan_timeout_ms = 25,
            path_scan_max = 25,
            path_scan_cache_ms = 25,
            csl_scan_max = 25,
            scan_cache_ttl_ms = 25,
            package_scan_max = 25,
            package_cache_ttl_ms = 25,
            package_cache_prewarm = false,
        },
    })
end)

assert(ok, err)
assert(
    config.get().output_dir == "",
    "empty output_dir should remain supported"
)
assert(
    vim.deep_equal(
        config.get().executable,
        { "typst", "--ignore-system-fonts" }
    ),
    "executable lists should be valid"
)
assert(
    config.get().metadata_version == "0.15.0",
    "metadata_version should be configurable"
)
assert(
    vim.deep_equal(config.get().viewer.open, { "viewer", "--reuse-instance" }),
    "viewer.open lists should be valid"
)
assert(
    type(config.get().viewer.reload) == "function",
    "viewer.reload callbacks should be valid"
)
assert(
    config.get().viewer.provider == "zathura",
    "viewer.provider should be configurable"
)
assert(
    config.get().viewer.providers.zathura.open == "zathura",
    "named viewer providers should be configurable"
)
assert(
    type(config.get().viewer.providers.zathura.reload) == "function",
    "provider reload callbacks should be valid"
)
assert(
    config.get().viewer.inverse == "viewer-inverse",
    "viewer inverse command should be configurable"
)
assert(
    config.get().viewer.capabilities.source_maps == true,
    "viewer source-map capability should be configurable"
)
assert(
    config.get().viewer.providers.zathura.inverse == "zathura-inverse",
    "provider inverse command should be valid"
)
assert(
    config.get().mappings.enabled == false,
    "mappings.enabled=false should remain supported"
)
assert(
    config.get().mappings.hover == "K",
    "hover mapping should be configurable"
)
assert(
    config.get().mappings.commands.watch == "<localleader>ll",
    "VimTeX-style watch mapping should default to localleader ll"
)
assert(
    config.get().mappings.commands.view == "<localleader>lv",
    "VimTeX-style view mapping should default to localleader lv"
)
assert(
    config.get().mappings.insert.math == "<M-m>",
    "insert mappings should be configurable"
)
assert(
    config.get().indent.enabled == false,
    "indent.enabled=false should remain supported"
)
assert(
    config.get().indent.formatexpr == false,
    "indent.formatexpr=false should remain supported"
)
assert(
    config.get().imaps.enabled == true,
    "imaps.enabled should be configurable"
)
assert(
    type(config.get().imaps.mappings[1].rhs) == "function",
    "imaps callback rhs should be configurable"
)
assert(
    config.get().matchparen.enabled == false,
    "matchparen.enabled=false should remain supported"
)
assert(
    config.get().project.import_scan == false,
    "project import scan should be configurable"
)
assert(
    config.get().project.import_scan_max_files == 25,
    "project import scan file cap should be configurable"
)
assert(
    config.get().project.import_scan_max_depth == 1,
    "project import scan depth should be configurable"
)
assert(
    config.get().project.import_scan_max_entries == 100,
    "project import scan entry cap should be configurable"
)
assert(
    vim.deep_equal(
        config.get().project.import_scan_skip_dirs,
        { "heavy", "generated" }
    ),
    "project import scan skip dirs should be configurable"
)
assert(
    config.get().project.index.max_file_bytes == 512,
    "project index static file cap should be configurable"
)
assert(
    config.get().project.index.large_file_policy == "headings-only",
    "project index large-file policy should be configurable"
)
assert(
    config.get().project.persist_main == false,
    "project explicit-main persistence should be configurable"
)
assert(
    config.get().diagnostics.list == "loclist",
    "diagnostics list backend should be configurable"
)
assert(
    config.get().diagnostics.fonts == false,
    "font diagnostics should be configurable"
)
assert(
    config.get().diagnostics.font_scan_timeout_ms == 25,
    "font diagnostics scan timeout should be configurable"
)
assert(config.get().docs == nil, "legacy docs config should not be retained")
assert(
    config.get().conceal.custom.math.customop == "*",
    "custom math conceal should be configurable"
)
assert(
    config.get().conceal.categories.lists == true,
    "list conceal should be configurable"
)
assert(
    config.get().conceal.categories.raw_blocks == true,
    "raw block conceal should be configurable"
)
assert(
    config.get().conceal.categories.raw_block_languages == true,
    "raw block language conceal should be configurable"
)
assert(
    config.get().conceal.categories.reference_markers == true,
    "reference marker conceal should be configurable"
)
assert(
    config.get().conceal.categories.function_wrappers.strong == true,
    "wrapper conceal defaults should be preserved"
)
assert(
    config.get().conceal.categories.function_wrappers.emph == false,
    "wrapper conceal toggles should be configurable"
)
assert(
    vim.deep_equal(config.get().compile.generic.compile, { "make", "{output}" }),
    "generic compile command should be valid"
)
assert(
    config.get().compile.generic.cwd == "{root}",
    "generic cwd template should be valid"
)
assert(
    config.get().compile.task.compile == "just",
    "task compile command should be valid"
)
assert(
    type(config.get().compile.task.output) == "function",
    "task output callback should be valid"
)
assert(
    type(config.get().format.provider) == "function",
    "format provider callbacks should be valid"
)
assert(
    config.get().format.prose_width == 64,
    "prose format width should be configurable"
)
assert(
    config.get().lint.provider.name == "custom-lint",
    "lint provider tables should be valid"
)
assert(
    config.get().log.max_entries == 0,
    "log.max_entries=0 should remain supported"
)
assert(
    config.get().preview.provider == "typst-preview.nvim",
    "preview provider should be configurable"
)
assert(
    config.get().preview.native == "browser",
    "native preview target should be configurable"
)
assert(
    config.get().preview.browser.port == 12345,
    "preview browser port should be configurable"
)
assert(
    config.get().preview.browser.server == false,
    "preview browser server mode should be configurable"
)
assert(
    config.get().preview.browser.allow_remote == true,
    "preview browser remote bind opt-in should be configurable"
)
assert(
    config.get().preview.browser.token == "test-preview-token",
    "preview browser remote token should be configurable"
)
assert(
    config.get().preview.browser.output_dir
        == typst_test_cache_path("browser-preview"),
    "preview browser output directory should be configurable"
)
assert(
    config.get().preview.browser.max_artifact_bytes == 4096,
    "preview browser artifact cap should be configurable"
)
assert(
    config.get().preview.browser.refresh_ms == 250,
    "preview browser refresh interval should be configurable"
)
assert(
    config.get().preview.browser.reload_throttle_ms == 500,
    "preview browser reload throttle should be configurable"
)
assert(
    config.get().preview.browser.performance == "fast",
    "preview browser performance mode should be configurable"
)
assert(
    config.get().preview.browser.app == "chrome",
    "preview browser app selector should be configurable"
)
assert(
    config.get().preview.browser.commands[1][1] == "test-browser-opener",
    "preview browser opener commands should be configurable"
)
assert(
    type(config.get().preview.browser.open) == "function",
    "preview browser opener callback should be configurable"
)
assert(
    config.get().preview.browser.style.variables.bg == "#101010",
    "preview browser style variables should be configurable"
)
assert(
    config.get().preview.browser.style.variables["--custom-preview-accent"]
        == "#ffcc00",
    "preview browser custom CSS variables should be configurable"
)
assert(
    config.get().preview.browser.style.css == "body { letter-spacing: 0; }",
    "preview browser inline CSS should be configurable"
)
assert(
    config.get().preview.browser.style.css_path
        == typst_test_config_path("browser-preview.css"),
    "preview browser CSS path should be configurable"
)
assert(
    config.get().preview.export.mode == "compile",
    "preview export mode should be configurable"
)
assert(
    config.get().preview.cache.max_entries == 3,
    "preview cache retention entry count should be configurable"
)
assert(
    config.get().preview.cache.max_bytes == 2048,
    "preview cache retention byte count should be configurable"
)
assert(
    config.get().preview.cache.ttl_ms == 500,
    "preview cache retention TTL should be configurable"
)
assert(
    config.get().preview.export.profile == "draft",
    "preview export profile should be configurable"
)
assert(
    config.get().preview.export.provider == "preview-export-provider",
    "preview export provider should be configurable"
)
assert(
    config.get().preview.export.output_format == "pdf",
    "preview export output format should be configurable"
)
assert(
    config.get().preview.export.output_name == "preview",
    "preview export output name should be configurable"
)
assert(
    config.get().preview.export.output_dir
        == typst_test_cache_path("preview-export"),
    "preview export output directory should be configurable"
)
assert(
    config.get().preview.export.extra_args[2] == "fonts",
    "preview export extra args should be configurable"
)
assert(
    config.get().preview.browser.export.mode == "compile",
    "preview browser export mode should be configurable"
)
assert(
    config.get().preview.browser.export.output_format == "svg",
    "preview browser export output format should be configurable"
)
assert(
    config.get().preview.browser.export.extra_args[2] == "html",
    "preview browser export extra args should be configurable"
)
assert(
    config.get().preview.capabilities.inverse == true,
    "preview inverse capability should be configurable"
)
assert(
    config.get().preview.capabilities.source_maps == true,
    "preview source-map capability should be configurable"
)
assert(
    config.get().preview.source_maps.provider == "preview-source-map-provider",
    "preview source-map provider should be configurable"
)
assert(
    type(config.get().preview.source_maps.forward) == "function",
    "preview source-map forward callback should be configurable"
)
assert(
    type(config.get().preview.source_maps.inverse) == "function",
    "preview source-map inverse callback should be configurable"
)
assert(
    config.get().preview.source_maps.capabilities.source_maps == true,
    "preview source-map capabilities should be configurable"
)
assert(
    config.get().preview.reuse == false,
    "preview reuse should be configurable"
)
assert(
    type(config.get().preview.refresh) == "function",
    "preview refresh callbacks should be valid"
)
assert(config.get().toc.mode == "quickfix", "TOC mode should be configurable")
assert(
    config.get().toc.position == "left",
    "TOC position should be configurable"
)
assert(config.get().toc.width == 40, "TOC width should be configurable")
assert(config.get().toc.height == 10, "TOC height should be configurable")
assert(
    config.get().toc.auto_close == true,
    "TOC auto-close should be configurable"
)
assert(
    config.get().toc.follow_cursor == false,
    "TOC cursor-following should be configurable"
)
assert(
    config.get().toc.highlight_current == false,
    "TOC current-section highlight should be configurable"
)
assert(
    config.get().toc.auto_refresh == false,
    "TOC auto-refresh should be configurable"
)
assert(
    config.get().toc.follow_delay_ms == 15,
    "TOC follow delay should be configurable"
)
assert(
    config.get().toc.refresh_delay_ms == 25,
    "TOC refresh delay should be configurable"
)
assert(
    config.get().toc.visible_layers.todo == false,
    "TOC visible layers should be configurable"
)
assert(
    config.get().toc.mappings.jump == "o",
    "TOC jump mapping should be configurable"
)
assert(
    config.get().toc.mappings.preview == "p",
    "TOC preview mapping should be configurable"
)
assert(
    config.get().toc.mappings.close == "x",
    "TOC close mapping should be configurable"
)
assert(
    config.get().toc.mappings.refresh == "R",
    "TOC refresh mapping should be configurable"
)
assert(
    config.get().toc.mappings.toggle == "z",
    "TOC heading toggle mapping should be configurable"
)
assert(
    config.get().toc.mappings.toggle_layer == "l",
    "TOC layer toggle mapping should be configurable"
)
assert(
    config.get().toc.mappings.filter == "f",
    "TOC filter mapping should be configurable"
)
assert(
    config.get().toc.mappings.clear_filter == "F",
    "TOC clear-filter mapping should be configurable"
)
assert(
    config.get().picker.provider == "fzf_vim",
    "fzf.vim picker provider should be configurable"
)
assert(
    config.get().picker.fzf_vim.down == "40%",
    "fzf.vim picker options should be configurable"
)
assert(
    config.get().completion.include_packages == true,
    "package completion should be configurable"
)
assert(
    config.get().completion.include_templates == false,
    "template completion should be configurable"
)
assert(
    config
        .get().completion.universe_index_paths[1]
        :find("universe%-index%.json"),
    "Universe index paths should be configurable"
)
assert(
    config.get().completion.include_paths == true,
    "path completion should be configurable"
)
assert(
    config.get().completion.include_csl_styles == true,
    "CSL style completion should be configurable"
)
assert(
    config.get().completion.csl_styles[1] == "custom-style",
    "custom CSL styles should be configurable"
)
assert(
    config.get().completion.include_raw_languages == true,
    "raw language completion should be configurable"
)
assert(
    config.get().completion.raw_languages[1] == "custom-raw-lang",
    "custom raw languages should be configurable"
)
assert(
    config.get().completion.include_colors == true,
    "color completion should be configurable"
)
assert(
    config.get().completion.color_names[1] == "brand-primary",
    "custom color names should be configurable"
)
assert(
    config.get().completion.include_fonts == true,
    "font completion should be configurable"
)
assert(
    config.get().completion.font_families[1] == "Unit Test Serif",
    "custom font families should be configurable"
)
assert(
    config.get().completion.font_scan_timeout_ms == 25,
    "font scan timeout should be configurable"
)
assert(
    config.get().completion.path_scan_max == 25,
    "path scan cap should be configurable"
)
assert(
    config.get().completion.path_scan_cache_ms == 25,
    "path scan cache TTL should be configurable"
)
assert(
    config.get().completion.csl_scan_max == 25,
    "CSL style scan cap should be configurable"
)
assert(
    config.get().completion.scan_cache_ttl_ms == 25,
    "completion scan cache TTL should be configurable"
)
assert(
    config.get().completion.package_scan_max == 25,
    "package completion scan cap should be configurable"
)
assert(
    config.get().completion.package_cache_ttl_ms == 25,
    "package cache TTL should be configurable"
)
assert(
    config.get().completion.package_cache_prewarm == false,
    "package cache prewarm should be configurable"
)
assert(
    config.get().render.cache.max_entries == 2,
    "render cache max_entries should be configurable"
)
assert(
    config.get().render.cache.max_bytes == 1024,
    "render cache max_bytes should be configurable"
)
assert(
    config.get().render.cache.ttl_ms == 250,
    "render cache TTL should be configurable"
)
assert(
    config.get().render.max_inline_image_bytes == 512,
    "render inline image limit should be configurable"
)
assert(
    config.get().render.source_dir
        == typst_test_cache_path("custom-render-sources"),
    "render source directory should be configurable"
)
assert(
    config.get().render.source_mode == "file",
    "render source mode should be configurable"
)
assert(
    config.get().compile.fragments.default == "custom",
    "fragment default template should be configurable"
)
assert(
    config.get().compile.fragments.source_dir
        == typst_test_cache_path("custom-fragment-sources"),
    "fragment source directory should be configurable"
)
assert(
    config
        .get().compile.fragments.templates.custom.prefix
        :find("fragment%-title"),
    "fragment table templates should be configurable"
)
assert(
    config.get().compile.fragments.templates.custom.source_dir
        == typst_test_cache_path("custom-template-sources"),
    "fragment template source directory should be configurable"
)
assert(
    config.get().compile.fragments.templates.inline == "{body}\n",
    "fragment string templates should be valid"
)

local templates = config.defaults().compile.fragments.templates
for _, name in ipairs({
    "markup",
    "math",
    "code",
    "full-page",
    "auto-sized",
    "document",
    "auto",
}) do
    assert(
        templates[name],
        ("default fragment template missing %s"):format(name)
    )
end

vim.cmd("qa!")
