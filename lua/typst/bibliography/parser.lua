local bibtex = require("typst.bibliography.bibtex")
local hayagriva = require("typst.bibliography.hayagriva")
local scan_cache = require("typst.core.scan_cache")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop

---@class TypstBibliographyCacheRecord
---@field signature string
---@field entries table[]
---@field by_key table<string, table>
---@field by_line table<number, table>

M.parse_bibtex_lines = bibtex.parse_bibtex_lines
M.parse_hayagriva_lines = hayagriva.parse_hayagriva_lines

local cache = scan_cache.new()

local function file_signature(path)
    local bufnr = util.loaded_buffer_for_path(path)
    if bufnr then
        -- Prefer loaded buffer text over disk so citation actions see unsaved
        -- bibliography edits during the same Neovim session.
        return ("buffer:%d"):format(vim.api.nvim_buf_get_changedtick(bufnr)),
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    local stat = type(path) == "string" and uv.fs_stat(path) or nil
    if not stat then
        return "missing", nil
    end

    return ("file:%d:%d:%d"):format(
        stat.size or 0,
        (stat.mtime and stat.mtime.sec) or 0,
        (stat.mtime and stat.mtime.nsec) or 0
    ),
        nil
end

local function read_lines(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or {}
end

local function cached_entries(path, kind, parse_lines)
    local signature, loaded_lines = file_signature(path)
    local key = ("%s\0%s"):format(kind, util.path_key(path or ""))
    local cached, fresh = scan_cache.peek(cache, key, {
        signature = signature,
    })
    if fresh then
        return cached.entries
    end

    -- Cache by parser kind as well as path; .bib and Hayagriva have different
    -- key/field rules even when a caller reuses the same file path.
    local entries = parse_lines(loaded_lines or read_lines(path))
    local by_key = {}
    local by_line = {}
    for _, entry in ipairs(entries or {}) do
        if entry.key then
            by_key[entry.key] = entry
        end
        if entry.lnum then
            by_line[entry.lnum] = entry
        end
    end

    cached = scan_cache.put(cache, key, {
        signature = signature,
        entries = entries,
        by_key = by_key,
        by_line = by_line,
    }, { signature = signature })
    return entries
end

local function cached_record(path, kind, parse_lines)
    cached_entries(path, kind, parse_lines)
    local key = ("%s\0%s"):format(kind, util.path_key(path or ""))
    local cached = scan_cache.peek(cache, key)
    return cached
end

function M.parse_bibtex_file(path)
    return cached_entries(path, "bibtex", bibtex.parse_bibtex_lines)
end

function M.bibtex_entry(path, key, lnum)
    local record = cached_record(path, "bibtex", bibtex.parse_bibtex_lines)
    if key and record.by_key[key] then
        return record.by_key[key]
    end
    if lnum and record.by_line[lnum] then
        return record.by_line[lnum]
    end
end

function M.bibtex_fields(path, key, lnum)
    local entry = M.bibtex_entry(path, key, lnum)
    return entry and entry.fields or {}
end

function M.parse_hayagriva_file(path)
    return cached_entries(path, "hayagriva", hayagriva.parse_hayagriva_lines)
end

function M.hayagriva_entry(path, key, lnum)
    local record =
        cached_record(path, "hayagriva", hayagriva.parse_hayagriva_lines)
    if key and record.by_key[key] then
        return record.by_key[key]
    end
    if lnum and record.by_line[lnum] then
        return record.by_line[lnum]
    end
end

function M.hayagriva_fields(path, key, lnum)
    local entry = M.hayagriva_entry(path, key, lnum)
    return entry and entry.fields or {}
end

function M.fields(path, key, lnum)
    local ext = vim.fn.fnamemodify(path or "", ":e"):lower()
    if ext == "bib" then
        return M.bibtex_fields(path, key, lnum)
    end
    if ext == "yml" or ext == "yaml" then
        return M.hayagriva_fields(path, key, lnum)
    end
    return {}
end

function M.reset()
    cache = scan_cache.new()
end

return M
