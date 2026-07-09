local default_editor = require("typst.config.default_editor")
local default_tools = require("typst.config.default_tools")
local xdg = require("typst.core.xdg")

local M = {}

function M.output_dir()
    return xdg.output_dir()
end

function M.fragments_output_dir()
    return xdg.fragments_output_dir()
end

function M.render_output_dir()
    return xdg.render_output_dir()
end

function M.render_source_dir()
    return xdg.render_source_dir()
end

function M.values()
    return {
        validation = "warn",
        executable = "typst",
        metadata_version = nil,
        output_format = "pdf",
        output_name = nil,
        output_dir = M.output_dir(),
        allow_external_output = false,
        root = nil,
        root_markers = { ".typstmain", "typst.toml", ".git" },
        main = nil,
        main_base_dir = nil,
        project = {
            import_scan = true,
            import_scan_command_wait_ms = 100,
            import_scan_max_files = 200,
            import_scan_max_depth = 3,
            import_scan_max_entries = 2000,
            import_scan_skip_dirs = {
                ".git",
                "node_modules",
                ".direnv",
                ".cache",
                "target",
                "build",
                "dist",
                "vendor",
                ".venv",
                "__pycache__",
            },
            persist_main = true,
            warn_on_low_confidence_main = true,
            index = {
                fs_watchers = "auto",
                max_file_bytes = 1024 * 1024,
                max_files = 512,
                max_entries = 4096,
                max_depth = 32,
                large_file_policy = "skip",
            },
        },
        integrations = {
            semantic = {
                provider = "tinymist",
            },
            tinymist = {
                lsp = "auto",
                client_names = { "tinymist" },
                path = "tinymist",
                cmd = nil,
                settings = {},
                init_options = {},
                capabilities = nil,
                on_attach = nil,
            },
        },
        api = {
            experimental_warnings = false,
        },
        compile = default_tools.compile(M.fragments_output_dir()),
        exports = {
            provider = nil,
            default = nil,
            profiles = {},
            timeout_ms = 10000,
        },
        diagnostics = default_tools.diagnostics(),
        bibliography = {
            completion = "auto",
            attachment_fields = { "pdf", "file", "attachment" },
            attachment_paths = {
                "{key}.pdf",
                "attachments/{key}.pdf",
                "pdf/{key}.pdf",
            },
        },
        format = default_tools.format(),
        lint = default_tools.lint(),
        viewer = default_tools.viewer(),
        preview = default_tools.preview(),
        render = {
            provider = nil,
            display_provider = nil,
            output_format = "svg",
            output_dir = M.render_output_dir(),
            source_mode = "stdin",
            source_dir = M.render_source_dir(),
            timeout_ms = 10000,
            cache = {
                enabled = true,
                max_entries = 128,
                max_bytes = 64 * 1024 * 1024,
                ttl_ms = 24 * 60 * 60 * 1000,
            },
            max_inline_image_bytes = 1024 * 1024,
            open = true,
        },
        syntax = default_editor.syntax(),
        conceal = default_editor.conceal(),
        completion = default_editor.completion(),
        picker = default_editor.picker(),
        structural_actions = default_editor.structural_actions(),
        folds = default_editor.folds(),
        toc = default_editor.toc(),
        indent = default_editor.indent(),
        matchparen = default_editor.matchparen(),
        imaps = default_editor.imaps(),
        mappings = default_editor.mappings(),
        log = default_editor.log(),
    }
end

return M
