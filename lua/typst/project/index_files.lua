local graph_dependencies = require("typst.project.graph.dependencies")
local graph_sources = require("typst.project.graph.sources")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop

--- Return the normalized path for a valid named buffer.
---@param bufnr? integer Buffer to inspect.
---@return string? path Normalized buffer path.
function M.buffer_path(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local path = vim.api.nvim_buf_get_name(bufnr)
    return path ~= "" and util.normalize(path) or nil
end

--- Return the project path represented by a buffer.
---@param project table Project state containing buffer resolutions.
---@param bufnr integer Buffer to inspect.
---@return string? path Real buffer path or scratch-main fallback.
function M.project_buffer_path(project, bufnr)
    local path = M.buffer_path(bufnr)
    if path then
        return path
    end

    local resolution = project
        and project.resolutions
        and project.resolutions[bufnr]
    if resolution and resolution.scratch then
        return project.main
    end
end

--- Find a loaded or listed buffer for a project file path.
---@param project table Project state whose buffers are searched.
---@param path string File path to match.
---@return integer? bufnr Matching buffer number.
function M.buffer_for_file(project, path)
    for bufnr in pairs(project.bufs or {}) do
        if util.same_path(M.project_buffer_path(project, bufnr), path) then
            return bufnr
        end
    end

    local bufnr = util.loaded_buffer_for_path(path) or vim.fn.bufnr(path)
    if bufnr > 0 then
        return bufnr
    end
end

--- Normalize text input into one string per line.
---@param lines table Raw lines that may contain embedded newlines.
---@return string[] lines Normalized line list.
function M.normalized_lines(lines)
    local normalized = {}
    for _, line in ipairs(lines or {}) do
        line = type(line) == "string" and line or tostring(line or "")
        if line:find("\n", 1, true) then
            vim.list_extend(normalized, vim.split(line, "\n", { plain = true }))
        else
            normalized[#normalized + 1] = line
        end
    end
    return normalized
end

--- Read source lines from a loaded buffer or disk file.
---@param project table Project state used for buffer lookup.
---@param path string File path to read.
---@return string[] lines Normalized source lines.
function M.read_lines(project, path)
    local bufnr = M.buffer_for_file(project, path)
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        return M.normalized_lines(
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        )
    end

    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and M.normalized_lines(lines) or {}
end

--- Build the initial file queue for project index traversal.
---@param project table Project state whose buffers/graph are inspected.
---@return string[] files Initial file paths.
---@return table seen Seen-key set for the returned files.
function M.initial_files(project)
    local files = {}
    local seen = {}

    local function add(path, opts)
        opts = opts or {}
        local normalized = path and util.normalize(path)
        local key = path and util.path_key(path) or nil
        local buffer = normalized and M.buffer_for_file(project, normalized)
        local source_like = opts.allow_non_typst
            or graph_sources.is_source_path(normalized)
            or (
                buffer ~= nil
                and vim.api.nvim_buf_is_valid(buffer)
                and vim.bo[buffer].filetype == "typst"
            )
        if
            normalized
            and key
            and not seen[key]
            and source_like
            and (vim.fn.filereadable(normalized) == 1 or buffer ~= nil)
        then
            seen[key] = true
            files[#files + 1] = normalized
        end
    end

    add(project.main, { allow_non_typst = true })
    for path in pairs(graph_sources.get(project)) do
        add(path)
    end
    for path in pairs(graph_dependencies.get(project)) do
        add(path)
    end
    for bufnr in pairs(project.bufs or {}) do
        add(M.project_buffer_path(project, bufnr))
    end

    return files, seen
end

--- Return a version signature for a project file.
---@param project table Project state used for buffer lookup.
---@param path string File path to version.
---@return string version Buffer changedtick or disk stat signature.
function M.file_version(project, path)
    local bufnr = M.buffer_for_file(project, path)
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        return ("buffer:%d"):format(vim.api.nvim_buf_get_changedtick(bufnr))
    end

    local stat = uv.fs_stat(path)
    if not stat then
        return "missing"
    end

    return ("file:%d:%d:%d"):format(
        stat.size or 0,
        stat.mtime.sec or 0,
        stat.mtime.nsec or 0
    )
end

--- Create a temporary Typst buffer for Tree-sitter parsing of lines.
---@param lines string[] Source lines to parse.
---@return integer bufnr Temporary buffer number.
function M.parse_buffer_for_lines(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.b[bufnr].typst_nvim_no_attach = 1
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.normalized_lines(lines))
    return bufnr
end

return M
