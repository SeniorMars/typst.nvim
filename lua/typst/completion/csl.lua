local config = require("typst.config")
local cache = require("typst.core.cache")
local scan_cache = require("typst.core.scan_cache")
local buffer_context = require("typst.core.buffer_context")
local completion_items = require("typst.completion.items")
local index = require("typst.index")
local util = require("typst.core.util")

local M = {}
local local_files_cache = scan_cache.new()

local fallback_styles = {
    "american-medical-association",
    "american-physics-society",
    "apa",
    "cell",
    "chicago-author-date",
    "chicago-notes",
    "chicago-fullnotes",
    "elsevier-harvard",
    "gb-7714-2015-author-date",
    "gb-7714-2015-numeric",
    "harvard-cite-them-right",
    "ieee",
    "iso-690-author-date",
    "modern-language-association",
    "mla",
    "nature",
    "science",
    "springer-basic-author-date",
    "vancouver",
}

local function item(word, fields)
    fields = fields or {}
    return {
        word = word,
        abbr = word,
        menu = fields.local_file and "[Typst CSL file]" or "[Typst CSL style]",
        kind = fields.local_file and "f" or "v",
        info = completion_items.info({
            fields.local_file and ("Path: " .. fields.path)
                or ("CSL style: " .. word),
            fields.source,
        }),
        user_data = {
            typst = {
                kind = "csl_style",
                provider = fields.local_file and "project" or "builtin",
                semantic = false,
                path = fields.path,
            },
        },
    }
end

local function style_names()
    local names = {}
    local seen = {}

    for _, name in ipairs(fallback_styles) do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    table.sort(names)
    return names
end

local function local_files(opts, completion_config)
    if completion_config.csl_scan_max == 0 then
        return {}
    end

    local root = opts.project and opts.project.root or nil
    if not root and opts.bufnr then
        local collected = index.collect({
            bufnr = opts.bufnr,
            project = opts.project,
        })
        root = collected and collected.project and collected.project.root or nil
    end
    root = root or vim.fn.getcwd()

    local stat = (vim.uv or vim.loop).fs_stat(root)
    local mtime = stat and stat.mtime
    local ttl_ms = completion_config.scan_cache_ttl_ms or 5000
    local now = cache.now_ms()
    local signature = {
        util.normalize(root),
        tostring(config.generation and config.generation() or 0),
        tostring(completion_config.csl_scan_max),
        tostring(ttl_ms),
        mtime and tostring(mtime.sec) or "",
        mtime and tostring(mtime.nsec) or "",
    }

    return scan_cache.get(local_files_cache, "local-files", {
        signature = signature,
        ttl_ms = ttl_ms,
        now_ms = now,
    }, function()
        local files = vim.fs.find(function(name, path)
            if not name:match("%.csl$") then
                return false
            end

            local normalized = util.normalize(path)
            return not normalized:find(
                util.path_sep() .. "%.typst%.nvim" .. util.path_sep(),
                1,
                true
            )
        end, {
            path = root,
            type = "file",
            limit = completion_config.csl_scan_max,
        })

        table.sort(files)
        return files
    end)
end

function M.items(opts, base, catalog)
    local completion_config = config.unsafe_get().completion
    if
        opts.include_csl_styles == false
        or completion_config.include_csl_styles == false
    then
        return {}
    end

    local items = {}
    local seen = {}
    local function add(word, fields)
        completion_items.add_unique(items, seen, word, function(value)
            return item(value, fields)
        end, { base = base, trim = false })
    end

    for _, style in ipairs(style_names()) do
        add(style, {
            source = ("Bundled Typst %s CSL style ID"):format(catalog.version),
        })
    end
    for _, style in ipairs(completion_config.csl_styles or {}) do
        add(style, { source = "Configured CSL style ID" })
    end

    local file_dir = buffer_context.file_dir(opts)
    for _, path in ipairs(local_files(opts, completion_config)) do
        add(util.relpath(path, file_dir), {
            local_file = true,
            path = path,
        })
    end

    table.sort(items, function(a, b)
        if a.menu == b.menu then
            return a.word < b.word
        end
        return a.menu < b.menu
    end)

    return items
end

function M.reset()
    scan_cache.reset(local_files_cache)
end

return M
