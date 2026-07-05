local config = require("typst.config")
local buffer_context = require("typst.core.buffer_context")
local completion_items = require("typst.completion.items")
local completion_match = require("typst.completion.match")
local coordinates = require("typst.core.coordinates")
local position = require("typst.completion.position")
local scan_cache = require("typst.core.scan_cache")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr
local directory_cache = scan_cache.new()

local path_function_kinds = {
    bibliography = "bibliography",
    image = "image",
    include = "import",
    read = "data",
    raw = "raw",
}

local path_extensions = {
    bibliography = {
        bib = true,
        yaml = true,
        yml = true,
    },
    image = {
        gif = true,
        jpeg = true,
        jpg = true,
        pdf = true,
        png = true,
        svg = true,
        webp = true,
    },
    import = {
        typ = true,
    },
}

local path_kind_labels = {
    bibliography = "bibliography",
    data = "data",
    image = "image",
    import = "import",
    raw = "raw",
}

local function context_label(kind)
    return path_kind_labels[kind] or "file"
end

local function item(word, fields)
    fields = fields or {}
    local label = context_label(fields.path_kind)
    local is_dir = fields.type == "directory"
    return {
        word = word,
        abbr = word,
        menu = is_dir and "[Typst directory]"
            or ("[Typst %s path]"):format(label),
        kind = is_dir and "d" or "f",
        info = completion_items.info({
            ("%s path: %s"):format(label:gsub("^%l", string.upper), word),
            fields.path and ("Path: " .. fields.path) or nil,
        }),
        user_data = {
            typst = {
                kind = "path",
                path_kind = fields.path_kind,
                provider = "filesystem",
                semantic = false,
                path = fields.path,
            },
        },
    }
end

local function base_parts(base, file_dir)
    base = base or ""
    local prefix, leaf = base:match("^(.*[/\\])([^/\\]*)$")
    prefix = prefix or ""
    leaf = leaf or base

    local scan_dir = prefix ~= "" and util.resolve_path(prefix, file_dir)
        or file_dir
    return prefix, leaf, scan_dir
end

local function allowed(kind, name, node_type)
    if name == ".git" then
        return false
    end

    if node_type == "directory" then
        return true
    end

    local allowed_extensions = path_extensions[kind]
    if not allowed_extensions then
        return true
    end

    local extension = name:match("%.([^%.]+)$")
    return extension and allowed_extensions[extension:lower()] or false
end

local function matches_leaf(name, leaf)
    if name:sub(1, 1) == "." and leaf:sub(1, 1) ~= "." then
        return false
    end

    return completion_match.prefix(name, leaf)
end

local function directory_signature(scan_dir)
    local stat = uv.fs_stat(scan_dir)
    if type(stat) ~= "table" then
        return "missing"
    end

    local mtime = stat.mtime or {}
    return scan_cache.signature({
        stat.type,
        stat.size,
        stat.ino,
        stat.dev,
        mtime.sec,
        mtime.nsec,
    })
end

local function cache_key(scan_dir, path_kind)
    return scan_cache.signature({
        util.path_key(scan_dir),
        path_kind,
    })
end

local function read_directory(scan_dir, path_kind, entry_max)
    local ok, iterator = pcall(vim.fs.dir, scan_dir)
    if not ok or not iterator then
        return nil
    end

    local entries = {}
    local seen = {}
    local cap = tonumber(entry_max)
    local scanned = 0
    for name, node_type in iterator do
        scanned = scanned + 1
        if not seen[name] and allowed(path_kind, name, node_type) then
            seen[name] = true
            entries[#entries + 1] = {
                name = name,
                type = node_type,
            }
        end
        if cap and cap > 0 and scanned >= cap then
            break
        end
    end
    return entries
end

local function directory_entries(scan_dir, completion_config, path_kind)
    local ttl_ms = tonumber(completion_config.path_scan_cache_ms) or 0
    if ttl_ms <= 0 then
        return read_directory(
            scan_dir,
            path_kind,
            completion_config.path_scan_entry_max
        )
    end

    local key = cache_key(scan_dir, path_kind)
    local signature = scan_cache.signature({
        directory_signature(scan_dir),
        ttl_ms,
        completion_config.path_scan_entry_max,
    })
    local cached, fresh = scan_cache.peek(directory_cache, key, {
        signature = signature,
        ttl_ms = ttl_ms,
    })
    if fresh then
        return cached
    end

    local entries = read_directory(
        scan_dir,
        path_kind,
        completion_config.path_scan_entry_max
    )
    if not entries then
        return nil
    end

    scan_cache.put(directory_cache, key, entries, {
        signature = signature,
        ttl_ms = ttl_ms,
    })
    return entries
end

local function build_items(entries, path_kind, prefix, leaf, file_dir, max)
    local items = {}
    local seen = {}
    for _, entry in ipairs(entries) do
        if #items >= max then
            break
        end

        local name = entry.name
        local node_type = entry.type
        if matches_leaf(name, leaf) then
            local suffix = node_type == "directory" and "/" or ""
            local word = prefix .. name .. suffix
            local path = util.resolve_path(prefix .. name, file_dir)
            completion_items.add_unique(items, seen, name, function()
                return item(word, {
                    path_kind = path_kind,
                    path = path,
                    type = node_type,
                })
            end, { base = leaf, key = name, trim = false })
        end
    end
    return items
end

function M.context_from_before(before)
    local start_col, source = before:match('#import%s+"()([^"]*)$')
    if start_col then
        if completion_match.starts_with(source, "@") then
            return nil
        end

        return {
            kind = "import",
            start_col = start_col - 1,
            base = source,
        }
    end

    start_col, source = before:match('#include%s+"()([^"]*)$')
    if start_col then
        return {
            kind = "import",
            start_col = start_col - 1,
            base = source,
        }
    end

    local function_name = nil
    for candidate, candidate_start, candidate_source in
        before:gmatch('([%w_.%-]+)%s*%(%s*"()([^"]*)$')
    do
        function_name = candidate
        start_col = candidate_start
        source = candidate_source
    end

    local kind = function_name and path_function_kinds[function_name]
    if not kind then
        return nil
    end

    return {
        kind = kind,
        start_col = start_col - 1,
        base = source,
    }
end

function M.context_info(bufnr, row, col)
    return M.context_from_before(
        coordinates.line_before_cursor(bufnr, row, col)
    )
end

function M.items(opts, base)
    local completion_config = config.unsafe_get().completion
    if
        opts.include_paths == false
        or completion_config.include_paths == false
    then
        return {}
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    local resolved = position.resolve(opts, bufnr)
    local row = resolved and resolved.row or nil
    local col = resolved and resolved.col or nil

    local context = opts.path_kind and { kind = opts.path_kind }
        or (row and col and M.context_info(bufnr, row, col))
    local path_kind = context and context.kind or opts.path_kind or "file"
    local file_dir = buffer_context.file_dir(opts)
    local prefix, leaf, scan_dir = base_parts(base or "", file_dir)
    if not scan_dir or vim.fn.isdirectory(scan_dir) ~= 1 then
        return {}
    end

    local max = completion_config.path_scan_max
    if max == 0 then
        return {}
    end

    local entries = directory_entries(scan_dir, completion_config, path_kind)
    if not entries then
        return {}
    end

    local items = build_items(entries, path_kind, prefix, leaf, file_dir, max)

    table.sort(items, function(a, b)
        if a.kind == b.kind then
            return a.word < b.word
        end
        return a.kind == "d"
    end)
    return items
end

function M.reset()
    scan_cache.reset(directory_cache)
end

return M
