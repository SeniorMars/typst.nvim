local xdg = require("typst.core.xdg")

local M = {}

function M.compile(fragments_output_dir)
    return {
        provider = nil,
        provider_timeout_ms = 10000,
        extra_args = {},
        watch_output = "auto",
        watch_output_wait_ms = 1500,
        watch_structured_args = {},
        deps = true,
        open = false,
        typst_open = false,
        profiles = {},
        generic = {
            compile = nil,
            watch = nil,
            output = nil,
            cwd = nil,
        },
        task = {
            compile = nil,
            watch = nil,
            output = nil,
            cwd = nil,
        },
        fragments = {
            default = "markup",
            output_dir = fragments_output_dir,
            source_dir = nil,
            templates = {
                markup = {
                    prefix = "",
                    suffix = "\n",
                },
                math = {
                    prefix = "$ ",
                    suffix = " $\n",
                },
                code = {
                    prefix = "#{\n",
                    suffix = "\n}\n",
                },
                document = {
                    prefix = "",
                    suffix = "\n",
                },
                ["full-page"] = {
                    prefix = "",
                    suffix = "\n",
                },
                auto = {
                    prefix = "#set page(width: auto, height: auto, margin: 0pt)\n",
                    suffix = "\n",
                },
                ["auto-sized"] = {
                    prefix = "#set page(width: auto, height: auto, margin: 0pt)\n",
                    suffix = "\n",
                },
            },
        },
    }
end

function M.diagnostics()
    return {
        enabled = true,
        source = "fallback",
        use_quickfix = false,
        list = "quickfix",
        max_external_buffers = 256,
        overflow = "quickfix-only",
        external_paths = "bufadd",
    }
end

function M.format()
    return {
        provider = "auto",
        command = "typstyle",
        extra_args = {},
        timeout_ms = 2000,
        prose_width = 80,
    }
end

function M.lint()
    return {
        provider = "typst",
        command = nil,
        extra_args = {},
        timeout_ms = 2000,
    }
end

function M.grammar()
    return {
        provider = "command",
        command = nil,
        extra_args = {},
        timeout_ms = 2000,
        stdin = nil,
        file_arg = nil,
    }
end

function M.viewer()
    return {
        provider = "generic",
        open = nil,
        reload = nil,
        args = {},
        forward = nil,
        forward_args = {},
        inverse = nil,
        inverse_args = {},
        providers = {
            generic = {},
            custom = {},
            zathura = {
                open = "zathura",
                args = { "--reuse-instance", "{output}" },
                capabilities = {
                    forward = false,
                    inverse = false,
                },
            },
            sioyek = {
                open = "sioyek",
                args = { "--reuse-window", "{output}" },
                capabilities = {
                    forward = false,
                    inverse = false,
                },
            },
            skim = {
                open = "open",
                args = { "-a", "Skim", "{output}" },
                capabilities = {
                    forward = false,
                    inverse = false,
                },
            },
            sumatrapdf = {
                open = "SumatraPDF.exe",
                args = { "-reuse-instance", "{output}" },
                capabilities = {
                    forward = false,
                    inverse = false,
                },
            },
            mupdf = {
                open = "mupdf",
                args = { "{output}" },
                capabilities = {
                    forward = false,
                    inverse = false,
                },
            },
            evince = {
                open = "evince",
                args = { "{output}" },
                capabilities = {
                    forward = false,
                    inverse = false,
                },
            },
            okular = {
                open = "okular",
                args = { "{output}" },
                capabilities = {
                    forward = false,
                    inverse = false,
                },
            },
            qpdfview = {
                open = "qpdfview",
                args = { "--unique", "{output}" },
                capabilities = {
                    forward = false,
                    inverse = false,
                },
            },
        },
    }
end

function M.preview()
    local export = {
        mode = "compile",
        profile = nil,
        provider = nil,
        output_format = nil,
        output_name = nil,
        output_dir = nil,
        extra_args = {},
    }

    return {
        provider = "native",
        native = "viewer",
        export = vim.deepcopy(export),
        cache = {
            enabled = true,
            max_entries = 32,
            max_bytes = 268435456,
            ttl_ms = 604800000,
        },
        open = nil,
        stop = nil,
        refresh = nil,
        forward = nil,
        inverse = nil,
        reuse = true,
        follow_buffer = false,
        capabilities = {
            forward = false,
            inverse = false,
            source_maps = false,
        },
        source_maps = {
            provider = "typst-query",
            forward = nil,
            inverse = nil,
            capabilities = {
                forward = false,
                inverse = false,
                source_maps = false,
            },
        },
        fallback = "view",
        browser = {
            host = "127.0.0.1",
            allow_remote = false,
            token = "auto",
            port = 0,
            server = true,
            output_dir = xdg.preview_output_dir(),
            max_artifact_bytes = 32 * 1024 * 1024,
            refresh_ms = 250,
            reload_throttle_ms = 0,
            performance = "default",
            app = nil,
            commands = nil,
            open = nil,
            style = {
                variables = {},
                css = nil,
                css_path = nil,
            },
            export = vim.tbl_extend("force", vim.deepcopy(export), {
                mode = "inherit",
            }),
        },
    }
end

return M
