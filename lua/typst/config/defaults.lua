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
        executable = "typst",
        metadata_version = nil,
        output_format = "pdf",
        output_name = nil,
        output_dir = M.output_dir(),
        allow_external_output = false,
        root = nil,
        root_markers = { ".typstmain", "typst.toml", ".git" },
        main = nil,
        project = {
            import_scan = true,
            import_scan_max_files = 200,
            import_scan_max_depth = 3,
            persist_main = true,
            index = {
                fs_watchers = "auto",
            },
        },
        integrations = {
            tinymist = {
                lsp = "auto",
                path = "tinymist",
                cmd = nil,
                settings = {},
                init_options = {},
                capabilities = nil,
                on_attach = nil,
            },
        },
        api = {},
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
        grammar = default_tools.grammar(),
        viewer = default_tools.viewer(),
        preview = default_tools.preview(),
        render = {
            provider = nil,
            display_provider = nil,
            output_format = "svg",
            output_dir = M.render_output_dir(),
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
