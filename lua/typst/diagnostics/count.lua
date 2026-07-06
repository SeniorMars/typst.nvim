local project = require("typst.project")
local config = require("typst.config")
local graph_sources = require("typst.project.graph.sources")
local lexical = require("typst.syntax.lexical")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function strip_line_comment(line)
    return lexical.strip_line_comment(line)
end

local function skip_control_line(line)
    local trimmed = vim.trim(line)
    return trimmed:match("^#import%f[%W]")
        or trimmed:match("^#include%f[%W]")
        or trimmed:match("^#let%f[%W]")
        or trimmed:match("^#set%f[%W]")
        or trimmed:match("^#show%f[%W]")
end

local function visible_text(text)
    text = tostring(text or "")
    text = text:gsub("```[%s%S]-```", " ")
    text = text:gsub("`[^`\n]*`", " ")
    text = text:gsub("%$[^%$\n]*%$", " ")

    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = strip_line_comment(line)
        if not skip_control_line(line) then
            line = line:gsub("^%s*=+%s*", "")
            line = line:gsub("^%s*[-+*]%s+", "")
            line = line:gsub("^%s*%d+[%.)]%s+", "")
            lines[#lines + 1] = line
        end
    end

    text = table.concat(lines, "\n")
    text = text:gsub("@[%w:_%-%.]+", " ")
    text = text:gsub("<[%w:_%-%.]+>", " ")
    text = text:gsub("#[%a_][%w_%.%-]*", " ")
    text = text:gsub("[%[%]{}()%*_=#]", " ")
    text = text:gsub("[%s]+", " ")
    return vim.trim(text)
end

local function count_visible(text)
    local visible = visible_text(text)
    local words = 0
    for _ in visible:gmatch("[%w][%w'%-]*") do
        words = words + 1
    end

    return {
        words = words,
        characters = vim.fn.strchars((visible:gsub("%s+", ""))),
        characters_with_spaces = vim.fn.strchars(visible),
        visible_text = visible,
    }
end

local function merge_counts(into, item)
    into.words = into.words + item.words
    into.characters = into.characters + item.characters
    into.characters_with_spaces = into.characters_with_spaces
        + item.characters_with_spaces
    into.lines = into.lines + item.lines
end

local function lines_text(lines)
    return table.concat(lines or {}, "\n")
end

local function count_file_policy(opts)
    opts = opts or {}
    local project_index = (config.unsafe_get().project or {}).index or {}
    local max_file_bytes = opts.max_file_bytes
    if max_file_bytes == nil then
        max_file_bytes = project_index.max_file_bytes
    end
    local large_file_policy = opts.large_file_policy
        or project_index.large_file_policy
        or "skip"
    if large_file_policy ~= "scan" and large_file_policy ~= "skip" then
        large_file_policy = "skip"
    end
    return {
        max_file_bytes = max_file_bytes,
        large_file_policy = large_file_policy,
    }
end

local function large_file_skip(path, opts)
    local policy = count_file_policy(opts)
    if
        policy.large_file_policy == "scan"
        or type(policy.max_file_bytes) ~= "number"
        or policy.max_file_bytes <= 0
    then
        return nil
    end

    local stat = uv and uv.fs_stat(path) or nil
    if stat and (stat.size or 0) > policy.max_file_bytes then
        return {
            skipped = true,
            reason = "large_file",
            path = util.normalize(path),
            bytes = stat.size or 0,
            max_file_bytes = policy.max_file_bytes,
            large_file_policy = policy.large_file_policy,
        }
    end
    return nil
end

---@class TypstCountResult
---@field scope string
---@field words integer
---@field characters integer
---@field characters_with_spaces integer
---@field lines integer
---@field files integer|nil
---@field path string|nil
---@field bufnr integer|nil
---@field skipped_count integer|nil
---@field skipped_files table<string, table>|nil

--- Count visible prose in a raw Typst text string.
---@param text string Typst source text.
---@return TypstCountResult result Count result scoped to text.
function M.text(text)
    local counted = count_visible(text)
    counted.lines = text == "" and 0
        or select(2, tostring(text or ""):gsub("\n", "\n")) + 1
    counted.scope = "text"
    return counted
end

--- Count visible prose in a buffer or selected buffer range.
---@param bufnr? integer Buffer to count.
---@param opts? table Count options, including range fields.
---@return TypstCountResult result Count result scoped to buffer or selection.
function M.buffer(bufnr, opts)
    bufnr = normalize_bufnr(bufnr)
    opts = opts or {}

    local start_line = opts.line1 and math.max(opts.line1 - 1, 0) or 0
    local end_line = opts.line2 and math.max(opts.line2, start_line) or -1
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
    local counted = count_visible(lines_text(lines))
    counted.lines = #lines
    counted.scope = opts.range and "selection" or "buffer"
    counted.bufnr = bufnr
    counted.path = vim.api.nvim_buf_get_name(bufnr)
    return counted
end

--- Count visible prose in a Typst file.
---@param path string File path to count.
---@param opts? table Count options.
---@return TypstCountResult? result Count result, or nil when the file is unreadable.
---@return table? skipped Skipped-file metadata when policy declines a file.
function M.file(path, opts)
    if not path or vim.fn.filereadable(path) ~= 1 then
        return nil
    end

    local bufnr = util.loaded_buffer_for_path(path)
    local lines
    if
        bufnr
        and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_is_loaded(bufnr)
    then
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    else
        local skipped = large_file_skip(path, opts)
        if skipped then
            return nil, skipped
        end
        local readfile = opts and opts.readfile or vim.fn.readfile
        local read_ok, read_result = pcall(readfile, path)
        if not read_ok then
            return nil,
                {
                    skipped = true,
                    reason = "read_failed",
                    path = util.normalize(path),
                    error = tostring(read_result),
                }
        end
        lines = read_result
    end
    local counted = count_visible(lines_text(lines))
    counted.lines = #lines
    counted.scope = "file"
    counted.path = util.normalize(path)
    counted.bufnr = bufnr
    return counted
end

--- Count visible prose across all indexed project files.
---@param state table Project state whose graph files are counted.
---@param opts? table Count options.
---@return TypstCountResult? result Project count result.
function M.project(state, opts)
    if not state then
        return nil
    end
    opts = opts or {}

    local result = {
        scope = "project",
        root = state.root,
        main = state.main,
        files = 0,
        words = 0,
        characters = 0,
        characters_with_spaces = 0,
        lines = 0,
        per_file = {},
        skipped_files = {},
        skipped_count = 0,
    }

    local paths = vim.tbl_keys(graph_sources.get(state))
    table.sort(paths)
    for _, path in ipairs(paths) do
        local counted, skipped = M.file(path, opts)
        if counted then
            result.files = result.files + 1
            result.per_file[path] = counted
            merge_counts(result, counted)
        elseif skipped then
            result.skipped_count = result.skipped_count + 1
            result.skipped_files[path] = skipped
        end
    end

    return result
end

--- Dispatch a count request for text, buffer/range, or project scope.
---@param opts? table Count options.
---@return TypstCountResult? result Count result.
function M.count(opts)
    opts = opts or {}
    if opts.text ~= nil then
        return M.text(opts.text)
    end

    local bufnr = normalize_bufnr(opts.bufnr)
    if opts.project then
        return M.project(
            opts.project == true and project.get(bufnr) or opts.project,
            opts
        )
    end

    return M.buffer(bufnr, {
        line1 = opts.line1,
        line2 = opts.line2,
        range = opts.range,
    })
end

--- Format a count result for user-facing reports.
---@param result? TypstCountResult Count result to format.
---@return string line Single-line count summary.
function M.format(result)
    if not result then
        return "Typst count: no project"
    end

    local label = result.scope or "buffer"
    local file_label = result.files and (" files=" .. result.files) or ""
    local skipped_label = (result.skipped_count or 0) > 0
            and (" skipped=" .. result.skipped_count)
        or ""
    return ("Typst count [%s]: words=%d chars=%d chars_with_spaces=%d lines=%d%s%s"):format(
        label,
        result.words or 0,
        result.characters or 0,
        result.characters_with_spaces or 0,
        result.lines or 0,
        file_label,
        skipped_label
    )
end

return M
