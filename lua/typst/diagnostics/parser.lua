local log = require("typst.core.log")
local util = require("typst.core.util")

local M = {}

---@class TypstDiagnosticEntry
---@field lnum integer
---@field col integer
---@field severity integer
---@field source string
---@field message string

---@class TypstDiagnosticParseMeta
---@field external_paths "bufadd"|"quickfix-only"|"open-files-only"
---@field max_buffers_per_publish integer
---@field added_buffers integer
---@field skipped_buffers integer
---@field skipped_by_cap integer
---@field skipped_external_paths integer
---@field first_skipped_path? string
---@field quickfix_only_diagnostics integer
---@field quickfix_items table[]

local severity = {
    error = vim.diagnostic.severity.ERROR,
    warning = vim.diagnostic.severity.WARN,
    warn = vim.diagnostic.severity.WARN,
    hint = vim.diagnostic.severity.HINT,
    help = vim.diagnostic.severity.HINT,
    info = vim.diagnostic.severity.INFO,
}

local function cache_key(path)
    return util.path_key and util.path_key(path) or path
end

local function default_max_buffers_per_publish()
    local ok, config = pcall(require, "typst.config")
    if not ok then
        return 256
    end
    local diagnostics = (config.unsafe_get().diagnostics or {})
    return tonumber(diagnostics.max_buffers_per_publish) or 256
end

local function default_external_paths()
    local ok, config = pcall(require, "typst.config")
    if not ok then
        return "bufadd"
    end
    local diagnostics = (config.unsafe_get().diagnostics or {})
    return diagnostics.external_paths or "bufadd"
end

local function normalize_external_paths(value)
    if
        value == "quickfix-only"
        or value == "open-files-only"
        or value == "bufadd"
    then
        return value
    end
    return "bufadd"
end

local function update_line_limit(line_cache, path, lnum)
    if not path or not lnum then
        return
    end
    line_cache.max_lines = line_cache.max_lines or {}
    local key = cache_key(path)
    local limit = math.max(tonumber(lnum) or 1, 1)
    line_cache.max_lines[key] = math.max(line_cache.max_lines[key] or 0, limit)
end

local function precompute_line_limits(project, text, line_cache)
    for _, line in ipairs(util.split_lines(text or "")) do
        local file, lnum = line:match("^(.-):(%d+):%d+:%s*%a+:%s*.*$")
        if not file then
            file, lnum = line:match("^(.-):(%d+):%d+:%s*.*$")
        end
        if not file then
            file, lnum = line:match("^%s*%S+%s+(.+):(%d+):%d+%s*$")
        end
        if not file then
            file, lnum = line:match("^%s*while%s+.-%s+at%s+(.+):(%d+):%d+%s*$")
        end
        if file then
            update_line_limit(
                line_cache,
                util.resolve_path(file, project.root),
                lnum
            )
        end
    end
end

local function lines_for_path(path, lnum, line_cache)
    line_cache = line_cache or {}
    local key = cache_key(path)
    local cached = line_cache[key]
    local requested = math.max((tonumber(lnum) or 0) + 1, 1)
    local limit = math.max(
        requested,
        line_cache.max_lines and line_cache.max_lines[key] or 0
    )
    if cached and (cached.max_read or 0) >= limit then
        return cached.lines
    end

    local entry = cached or { lines = nil }
    local loaded = util.loaded_buffer_for_path(path)
    if loaded and vim.api.nvim_buf_is_valid(loaded) then
        entry.bufnr = loaded
        entry.changedtick = vim.api.nvim_buf_get_changedtick(loaded)
        entry.lines = vim.api.nvim_buf_get_lines(loaded, 0, limit, false)
        entry.max_read = limit
    elseif vim.fn.filereadable(path) == 1 then
        local ok, lines = pcall(vim.fn.readfile, path, "", limit)
        if ok and type(lines) == "table" then
            entry.lines = lines
            entry.max_read = limit
        end
    end
    line_cache[key] = entry
    return entry.lines
end

local function clamp_col_for_path(path, lnum, col, line_cache)
    local lines = lines_for_path(path, lnum, line_cache)
    local line = lines and lines[lnum + 1] or nil

    if line == nil then
        return math.max(col or 0, 0)
    end
    -- External tools report byte-ish columns that may point past the loaded
    -- line after edits or Unicode normalization. Clamp against the current
    -- buffer/file so vim.diagnostic never receives an invalid range.
    return math.min(math.max(col or 0, 0), #line)
end

local function diagnostic_position(path, lnum, col, line_cache)
    local row = math.max((tonumber(lnum) or 1) - 1, 0)
    local byte_col = math.max((tonumber(col) or 1) - 1, 0)
    return row, clamp_col_for_path(path, row, byte_col, line_cache)
end

local function parse_line(line, project, opts)
    opts = opts or {}
    local file, lnum, col, level, message =
        line:match("^(.-):(%d+):(%d+):%s*(%a+):%s*(.*)$")
    if not file then
        file, lnum, col, message = line:match("^(.-):(%d+):(%d+):%s*(.*)$")
        level = "error"
    end

    if not file then
        return nil
    end

    local path = util.resolve_path(file, project.root)
    lnum, col = diagnostic_position(path, lnum, col, opts.line_cache)
    return path,
        {
            lnum = lnum,
            col = col,
            severity = severity[level:lower()] or vim.diagnostic.severity.ERROR,
            source = opts.source or "typst",
            message = message ~= "" and message or line,
        }
end

local function diagnostic_for(project, file, lnum, col, level, message, opts)
    local path = util.resolve_path(file, project.root)
    lnum, col = diagnostic_position(path, lnum, col, opts.line_cache)
    return path,
        {
            lnum = lnum,
            col = col,
            severity = severity[(level or "error"):lower()]
                or vim.diagnostic.severity.ERROR,
            source = opts.source or "typst",
            message = message ~= "" and message
                or ("%s:%s:%s"):format(file, lnum, col),
        }
end

local function parse_pretty_location(line, project, pending, opts)
    if not pending then
        return nil
    end

    local file, lnum, col = line:match("^%s*%S+%s+(.+):(%d+):(%d+)%s*$")
    if not file then
        return nil
    end

    return diagnostic_for(
        project,
        file,
        lnum,
        col,
        pending.level,
        pending.message,
        opts
    )
end

local function parse_pretty_context(line, project, opts)
    local message, file, lnum, col =
        line:match("^%s*(while%s+.-)%s+at%s+(.+):(%d+):(%d+)%s*$")
    if not message then
        return nil
    end

    return diagnostic_for(project, file, lnum, col, "help", message, opts)
end

--- Parse Typst diagnostic output into Neovim diagnostics grouped by buffer.
---@param project table Project state used to resolve relative diagnostic paths.
---@param text string Raw stderr/stdout diagnostic text from Typst or a compatible provider.
---@param opts? table Parser options such as diagnostic source and path handling.
---@return table<number, table[]> by_buffer Diagnostics keyed by Neovim buffer number.
---@return TypstDiagnosticParseMeta meta Diagnostic path/buffer handling metadata.
function M.parse(project, text, opts)
    opts = opts or {}
    local parse_opts = vim.tbl_extend("force", opts, {
        line_cache = {},
    })
    precompute_line_limits(project, text, parse_opts.line_cache)
    local by_buffer = {}
    local pending_pretty = nil
    local max_buffers = tonumber(parse_opts.max_buffers_per_publish)
        or default_max_buffers_per_publish()
    local external_paths = normalize_external_paths(
        parse_opts.external_paths or default_external_paths()
    )
    local new_buffer_count = 0
    local skipped_by_cap = 0
    local skipped_external_count = 0
    local quickfix_only_count = 0
    local first_skipped_path = nil
    local quickfix_by_path = {}

    local function loaded_bufnr(path)
        local loaded = util.loaded_buffer_for_path(path)
        if loaded and vim.api.nvim_buf_is_valid(loaded) then
            return loaded
        end

        local existing = vim.fn.bufnr(path)
        if
            existing > 0
            and vim.api.nvim_buf_is_valid(existing)
            and vim.api.nvim_buf_is_loaded(existing)
        then
            return existing
        end
    end

    local function add_quickfix_only(path, diagnostic)
        quickfix_by_path[path] = quickfix_by_path[path] or {}
        table.insert(quickfix_by_path[path], diagnostic)
        quickfix_only_count = quickfix_only_count + 1
    end

    local function add(path, diagnostic)
        local loaded = loaded_bufnr(path)
        if loaded then
            by_buffer[loaded] = by_buffer[loaded] or {}
            table.insert(by_buffer[loaded], diagnostic)
            return
        end

        if external_paths == "open-files-only" then
            skipped_external_count = skipped_external_count + 1
            first_skipped_path = first_skipped_path or path
            return
        end

        if external_paths == "quickfix-only" then
            add_quickfix_only(path, diagnostic)
            return
        end

        -- Default `bufadd` mode intentionally creates unloaded buffers so
        -- vim.diagnostic can own external-path diagnostics. This is bounded by
        -- max_buffers_per_publish; use quickfix-only/open-files-only to avoid
        -- hidden buffers on large or remote projects.
        local existing = vim.fn.bufnr(path)
        if
            existing <= 0
            and max_buffers > 0
            and new_buffer_count >= max_buffers
        then
            skipped_by_cap = skipped_by_cap + 1
            first_skipped_path = first_skipped_path or path
            return
        end

        local bufnr = vim.fn.bufadd(path)
        if existing <= 0 and by_buffer[bufnr] == nil then
            new_buffer_count = new_buffer_count + 1
        end
        by_buffer[bufnr] = by_buffer[bufnr] or {}
        table.insert(by_buffer[bufnr], diagnostic)
    end

    -- Accept both short `file:line:col: level: message` output and Typst's
    -- pretty two-line diagnostics. The parser intentionally stays tolerant so
    -- older Typst releases and external lint providers can share this path.
    for _, line in ipairs(util.split_lines(text)) do
        local path, diagnostic = parse_line(line, project, parse_opts)
        if path and diagnostic then
            add(path, diagnostic)
        else
            local level, message = line:match("^%s*(%a+):%s*(.*)$")
            if level and severity[level:lower()] then
                pending_pretty = {
                    level = level,
                    message = message,
                }
            else
                path, diagnostic = parse_pretty_location(
                    line,
                    project,
                    pending_pretty,
                    parse_opts
                )
                if path and diagnostic then
                    add(path, diagnostic)
                    pending_pretty = nil
                else
                    path, diagnostic =
                        parse_pretty_context(line, project, parse_opts)
                    if path and diagnostic then
                        add(path, diagnostic)
                    end
                end
            end
        end
    end

    if skipped_by_cap > 0 then
        log.add("warn", "diagnostic buffer limit reached", {
            main = project and project.main,
            max_buffers_per_publish = max_buffers,
            skipped_buffers = skipped_by_cap,
            first_skipped_path = first_skipped_path,
        })
    end

    local quickfix_items = nil
    if next(quickfix_by_path) ~= nil then
        quickfix_items =
            require("typst.diagnostics.quickfix").path_items(quickfix_by_path)
    end

    return by_buffer,
        {
            external_paths = external_paths,
            max_buffers_per_publish = max_buffers,
            added_buffers = new_buffer_count,
            skipped_buffers = skipped_by_cap + skipped_external_count,
            skipped_by_cap = skipped_by_cap,
            skipped_external_paths = skipped_external_count,
            first_skipped_path = first_skipped_path,
            quickfix_only_diagnostics = quickfix_only_count,
            quickfix_items = quickfix_items or {},
        }
end

return M
