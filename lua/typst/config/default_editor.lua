local M = {}

function M.syntax()
    return {
        package_extensions = true,
        package_semantic_proof = "auto",
        package_highlight_group = "TypstPackageSpecial",
        package_highlight_priority = 115,
        packages = {
            ["@preview/cetz"] = {
                name = "cetz",
                highlight_group = "TypstPackageCetz",
                capture = "@typst.package.cetz",
                members = {
                    "anchor",
                    "bezier",
                    "canvas",
                    "circle",
                    "content",
                    "draw",
                    "group",
                    "hide",
                    "line",
                    "path",
                    "rect",
                    "rotate",
                    "scale",
                    "translate",
                },
            },
        },
    }
end

function M.conceal()
    return {
        enabled = true,
        reveal = "node",
        conceallevel = 2,
        viewport_margin = 25,
        categories = {
            math_symbols = true,
            math_scripts = true,
            math_delimiters = true,
            markup_delimiters = true,
            headings = false,
            lists = false,
            raw_blocks = false,
            raw_block_languages = false,
            labels = false,
            reference_markers = false,
            function_wrappers = {
                strong = true,
                emph = true,
                underline = true,
                strike = true,
            },
            emoji = false,
        },
        safety = {
            max_display_width = 1,
            allow_combining = false,
        },
        custom = {
            math = {},
        },
    }
end

function M.completion()
    return {
        include_packages = true,
        include_templates = true,
        universe_index_paths = {},
        include_paths = true,
        include_csl_styles = true,
        csl_styles = {},
        include_raw_languages = true,
        raw_languages = {},
        include_colors = true,
        color_names = {},
        include_fonts = true,
        font_families = {},
        font_scan_timeout_ms = 250,
        path_scan_max = 200,
        csl_scan_max = 100,
        scan_cache_ttl_ms = 5000,
        package_scan_max = 500,
        package_cache_ttl_ms = 5000,
        package_cache_prewarm = false,
    }
end

function M.picker()
    return {
        provider = "auto",
        kinds = {
            "headings",
            "figures",
            "tables",
            "equations",
            "labels",
            "references",
            "citations",
            "imports",
            "files",
            "todos",
            "definitions",
        },
        custom = nil,
        telescope = {},
        fzf_lua = {},
        fzf_vim = {},
        snacks = {},
    }
end

function M.structural_actions()
    return {
        timeout_ms = 1000,
        patterns = {
            heading_promote = {
                "promote.*heading",
                "heading.*promote",
                "level.*up",
                "decrease.*heading",
            },
            heading_demote = {
                "demote.*heading",
                "heading.*demote",
                "level.*down",
                "increase.*heading",
            },
            equation_toggle = {
                "toggle.*equation",
                "convert.*equation",
                "equation.*style",
                "inline.*block",
                "block.*inline",
            },
            equation_inline = {
                "inline.*equation",
                "equation.*inline",
                "convert.*inline",
            },
            equation_block = {
                "block.*equation",
                "equation.*block",
                "convert.*block",
            },
        },
    }
end

function M.folds()
    return {
        enabled = true,
        mode = "expr",
        foldlevel = 99,
        foldtext = true,
        text = nil,
        headings = true,
        imports = true,
        comments = false,
        content_blocks = true,
        code_blocks = true,
        calls = false,
        equations = true,
        raw_blocks = true,
        arrays = false,
        dictionaries = false,
        bibliography = true,
    }
end

function M.toc()
    return {
        mode = "window",
        position = "right",
        width = 32,
        height = 12,
        auto_close = false,
        follow_cursor = true,
        highlight_current = true,
        auto_refresh = true,
        follow_delay_ms = 40,
        refresh_delay_ms = 120,
        visible_layers = {
            heading = true,
            figure = true,
            table = true,
            equation = true,
            label = true,
            reference = true,
            citation = true,
            import = true,
            file = true,
            todo = true,
            definition = true,
        },
        mappings = {
            enabled = true,
            jump = "<CR>",
            preview = "p",
            close = "q",
            refresh = "r",
            toggle = "za",
            toggle_layer = "L",
            filter = "/",
            clear_filter = "\\",
        },
    }
end

function M.indent()
    return {
        enabled = true,
        formatexpr = true,
    }
end

function M.matchparen()
    return {
        enabled = true,
    }
end

function M.imaps()
    return {
        enabled = false,
        builtins = true,
        mappings = {},
    }
end

function M.mappings()
    return {
        enabled = true,
        next_heading = "]]",
        previous_heading = "[[",
        next_heading_end = "][",
        previous_heading_end = "[]",
        next_block = "]m",
        previous_block = "[m",
        next_block_end = "]M",
        previous_block_end = "[M",
        next_equation = "]n",
        previous_equation = "[n",
        next_equation_end = "]N",
        previous_equation_end = "[N",
        next_raw_block = "]r",
        previous_raw_block = "[r",
        next_comment = "]/",
        previous_comment = "[/",
        match = "%",
        follow = "gf",
        hover = false,
        repeat_transform = ".",
        commands = {
            watch = "<localleader>ll",
            compile = "<localleader>lL",
            stop = "<localleader>lk",
            view = "<localleader>lv",
            forward = "<localleader>ls",
            errors = "<localleader>le",
            output = "<localleader>lo",
            info = "<localleader>li",
            toc = "<localleader>lt",
            clean = "<localleader>lc",
            log = "<localleader>lg",
        },
        insert = {
            strong = false,
            emph = false,
            math = false,
            content = false,
            code = false,
            raw = false,
        },
        textobjects = {
            inner_heading = "ih",
            outer_heading = "ah",
            inner_section = "iH",
            outer_section = "aH",
            inner_equation = "im",
            outer_equation = "am",
            inner_delimiter = "id",
            outer_delimiter = "ad",
            inner_content = "ic",
            outer_content = "ac",
            inner_block = "ib",
            outer_block = "ab",
            inner_structural_block = "ie",
            outer_structural_block = "ae",
            inner_code_block = "iC",
            outer_code_block = "aC",
            inner_raw_block = "ir",
            outer_raw_block = "ar",
            inner_call = "if",
            outer_call = "af",
            inner_argument = "ia",
            outer_argument = "aa",
            inner_list_item = false,
            outer_list_item = false,
            inner_label = "il",
            outer_label = "al",
            inner_import = "ii",
            outer_import = "ai",
        },
    }
end

function M.log()
    return {
        max_entries = 200,
    }
end

return M
