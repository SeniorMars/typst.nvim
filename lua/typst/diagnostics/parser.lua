local util = require("typst.core.util")

local M = {}

---@class TypstDiagnosticEntry
---@field lnum integer
---@field col integer
---@field severity integer
---@field source string
---@field message string

local severity = {
    error = vim.diagnostic.severity.ERROR,
    warning = vim.diagnostic.severity.WARN,
    warn = vim.diagnostic.severity.WARN,
    hint = vim.diagnostic.severity.HINT,
    help = vim.diagnostic.severity.HINT,
    info = vim.diagnostic.severity.INFO,
}

local function clamp_col_for_path(path, lnum, col)
    local line = nil
    local loaded = util.loaded_buffer_for_path(path)
    if loaded and vim.api.nvim_buf_is_valid(loaded) then
        line = vim.api.nvim_buf_get_lines(loaded, lnum, lnum + 1, false)[1]
    elseif vim.fn.filereadable(path) == 1 then
        local ok, lines = pcall(vim.fn.readfile, path, "", lnum + 1)
        if ok and type(lines) == "table" then
            line = lines[lnum + 1] or ""
        end
    end

    if line == nil then
        return math.max(col or 0, 0)
    end
    -- External tools report byte-ish columns that may point past the loaded
    -- line after edits or Unicode normalization. Clamp against the current
    -- buffer/file so vim.diagnostic never receives an invalid range.
    return math.min(math.max(col or 0, 0), #line)
end

local function diagnostic_position(path, lnum, col)
    local row = math.max((tonumber(lnum) or 1) - 1, 0)
    local byte_col = math.max((tonumber(col) or 1) - 1, 0)
    return row, clamp_col_for_path(path, row, byte_col)
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
    lnum, col = diagnostic_position(path, lnum, col)
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
    lnum, col = diagnostic_position(path, lnum, col)
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
function M.parse(project, text, opts)
    opts = opts or {}
    local by_buffer = {}
    local pending_pretty = nil

    local function add(path, diagnostic)
        local bufnr = vim.fn.bufadd(path)
        by_buffer[bufnr] = by_buffer[bufnr] or {}
        table.insert(by_buffer[bufnr], diagnostic)
    end

    -- Accept both short `file:line:col: level: message` output and Typst's
    -- pretty two-line diagnostics. The parser intentionally stays tolerant so
    -- older Typst releases and external lint providers can share this path.
    for _, line in ipairs(util.split_lines(text)) do
        local path, diagnostic = parse_line(line, project, opts)
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
                path, diagnostic =
                    parse_pretty_location(line, project, pending_pretty, opts)
                if path and diagnostic then
                    add(path, diagnostic)
                    pending_pretty = nil
                else
                    path, diagnostic = parse_pretty_context(line, project, opts)
                    if path and diagnostic then
                        add(path, diagnostic)
                    end
                end
            end
        end
    end

    return by_buffer
end

return M
