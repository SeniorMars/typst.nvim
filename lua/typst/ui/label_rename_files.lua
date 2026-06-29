local util = require("typst.core.util")
local transaction = require("typst.ui.label_rename_transaction")

local M = {}

-- Prepare per-file edits for label rename.
--
-- Loaded buffers are edited through buffer APIs, while unloaded files are staged
-- on disk. Both paths validate expected text so stale index results fail closed.
local uv = vim.uv or vim.loop

local function edit_text(line, edit)
    if type(line) ~= "string" then
        return nil
    end

    return line:sub(edit.start_col + 1, edit.end_col)
end

local function copy_lines(lines)
    local copied = {}
    for index_, line in ipairs(lines or {}) do
        copied[index_] = line
    end
    return copied
end

local function prepare_renamed_lines(lines, edits)
    for _, edit in ipairs(edits) do
        local lnum = edit.row + 1
        local line = lines[lnum]
        if
            not line
            or (edit.expected and edit_text(line, edit) ~= edit.expected)
        then
            return nil, "stale_source"
        end
    end

    local renamed = copy_lines(lines)
    for _, edit in ipairs(edits) do
        local lnum = edit.row + 1
        local line = renamed[lnum]
        renamed[lnum] = line:sub(1, edit.start_col)
            .. edit.replacement
            .. line:sub(edit.end_col + 1)
    end
    return renamed
end

local function read_file_checked(path)
    if vim.fn.filereadable(path) ~= 1 then
        return nil, "unreadable"
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return nil, "unreadable"
    end
    return lines
end

local function sibling_temp_path(path, marker)
    -- Keep temp and backup siblings of the destination so rename stays on the
    -- same filesystem and is as atomic as libuv allows.
    local parent = util.dirname(path)
    local stem = util.basename(path)
    for attempt = 1, 100 do
        local candidate = util.join(
            parent,
            (".%s.typst-nvim-%s-%s-%d"):format(
                stem,
                marker,
                tostring(uv.hrtime()),
                attempt
            )
        )
        if not uv.fs_stat(candidate) then
            return candidate
        end
    end
end

local function validate_disk_writable(path)
    if vim.fn.filewritable(path) ~= 1 then
        return nil, "not_writable"
    end

    local parent = util.dirname(path)
    if vim.fn.isdirectory(parent) ~= 1 or vim.fn.filewritable(parent) ~= 2 then
        return nil, "directory_not_writable"
    end

    return true
end

function M.prepare(path, edits)
    path = util.normalize(path)
    local bufnr = util.loaded_buffer_for_path(path)
    if bufnr then
        if
            not vim.api.nvim_buf_is_valid(bufnr)
            or not vim.api.nvim_buf_is_loaded(bufnr)
        then
            return nil, "unreadable"
        end
        if not vim.bo[bufnr].modifiable then
            return nil, "buffer_not_modifiable"
        end

        local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
        if not ok or type(lines) ~= "table" then
            return nil, "unreadable"
        end

        local renamed, reason = prepare_renamed_lines(lines, edits)
        if not renamed then
            return nil, reason
        end
        return {
            bufnr = bufnr,
            path = path,
            original_lines = lines,
            lines = renamed,
            modified = vim.bo[bufnr].modified,
            edits = edits,
        }
    end

    local lines, read_reason = read_file_checked(path)
    if not lines then
        return nil, read_reason
    end

    local writable, write_reason = validate_disk_writable(path)
    if not writable then
        return nil, write_reason
    end

    local renamed, edit_reason = prepare_renamed_lines(lines, edits)
    if not renamed then
        return nil, edit_reason
    end

    local temp_path = sibling_temp_path(path, "rename")
    local backup_path = sibling_temp_path(path, "backup")
    if not temp_path or not backup_path then
        return nil, "temp_path_failed"
    end

    return {
        path = path,
        original_lines = lines,
        lines = renamed,
        edits = edits,
        temp_path = temp_path,
        backup_path = backup_path,
    }
end

M.apply = transaction.apply

return M
