local config = require("typst.config")
local cache = require("typst.core.cache")
local scan_cache = require("typst.core.scan_cache")
local completion_items = require("typst.completion.items")

local M = {}
local runtime_cache = scan_cache.new()

local fallback_languages = {
    "bash",
    "bibtex",
    "c",
    "c++",
    "c#",
    "css",
    "diff",
    "go",
    "html",
    "java",
    "javascript",
    "json",
    "julia",
    "latex",
    "lua",
    "make",
    "markdown",
    "mermaid",
    "nix",
    "python",
    "r",
    "ruby",
    "rust",
    "sh",
    "sql",
    "toml",
    "tsv",
    "typescript",
    "typst",
    "vim",
    "xml",
    "yaml",
    "zsh",
}

local function runtime_parser_languages()
    local completion_config = config.unsafe_get().completion
    local ttl_ms = completion_config.scan_cache_ttl_ms or 5000
    local now = cache.now_ms()
    local signature = {
        vim.o.runtimepath,
        tostring(config.generation and config.generation() or 0),
        tostring(ttl_ms),
    }

    return scan_cache.get(runtime_cache, "runtime-parsers", {
        signature = signature,
        ttl_ms = ttl_ms,
        now_ms = now,
    }, function()
        local seen = {}
        local languages = {}

        for _, pattern in ipairs({
            "parser/*.so",
            "parser/*.dll",
            "parser/*.dylib",
        }) do
            for _, path in ipairs(vim.api.nvim_get_runtime_file(pattern, true)) do
                local name = vim.fn.fnamemodify(path, ":t:r")
                if name ~= "" and not seen[name] then
                    seen[name] = true
                    languages[#languages + 1] = name
                end
            end
        end

        table.sort(languages)
        return languages
    end)
end

local function item(word, provider)
    return {
        word = word,
        abbr = word,
        menu = "[Typst raw language]",
        kind = "k",
        info = completion_items.info({
            ("Raw block language: %s"):format(word),
            provider == "runtime"
                    and "Detected from installed Tree-sitter parsers"
                or nil,
            provider == "config" and "Configured raw block language" or nil,
        }),
        user_data = {
            typst = {
                kind = "raw_language",
                provider = provider,
                semantic = false,
            },
        },
    }
end

function M.items(opts, base)
    local completion_config = config.unsafe_get().completion
    if
        opts.include_raw_languages == false
        or completion_config.include_raw_languages == false
    then
        return {}
    end

    local items = {}
    local seen = {}
    local function add(word, provider)
        completion_items.add_unique(items, seen, word, function(value)
            return item(value, provider)
        end, { base = base })
    end

    for _, language in ipairs(fallback_languages) do
        add(language, "builtin")
    end
    for _, language in ipairs(completion_config.raw_languages or {}) do
        add(language, "config")
    end
    for _, language in ipairs(runtime_parser_languages()) do
        add(language, "runtime")
    end

    table.sort(items, function(a, b)
        return a.word < b.word
    end)
    return items
end

function M.reset()
    scan_cache.reset(runtime_cache)
end

return M
