local path_util = require("typst.core.path")
local owned_path = require("typst.core.owned_path")

-- File helpers used by workflows that edit bibliography or generated sidecar
-- files. Temporary, backup, and journal files are kept next to the target so
-- replacement stays on the same filesystem and durable mode can fsync the
-- directory that actually owns the rename.
local M = {}

local uv = vim.uv or vim.loop
local temp_counter = 0

--- Check whether a path is a readable file.
---@param path? string File path to inspect.
---@return boolean readable True when Neovim can read the file.
function M.readable(path)
    return type(path) == "string"
        and path ~= ""
        and vim.fn.filereadable(path) == 1
end

--- Create the parent directory for a path when needed.
---@param path string Target path whose parent should exist.
---@return boolean ok True when the parent exists or was created.
---@return any error Error object/message when creation failed.
function M.ensure_parent(path)
    local parent = vim.fs.dirname(path)
    if parent and parent ~= "" then
        local ok, result = pcall(vim.fn.mkdir, parent, "p")
        if not ok then
            return false, result
        end
        if result == 0 and vim.fn.isdirectory(parent) ~= 1 then
            return false,
                ("failed to create parent directory %s"):format(parent)
        end
    end
    return true
end

--- Write lines to a file and normalize writefile failures.
---@param lines string[] Lines to write.
---@param path string Destination path.
---@return boolean ok True when writefile succeeded.
---@return any error Error object/message when writing failed.
function M.writefile_checked(lines, path)
    local ok, result = pcall(vim.fn.writefile, lines, path)
    if not ok then
        return false, result
    end
    if result ~= 0 then
        return false, ("writefile returned %s"):format(vim.inspect(result))
    end
    return true
end

--- Delete a file/directory and normalize delete failures.
---@param path string Path to delete.
---@param flags? string Flags forwarded to `delete()`.
---@return boolean ok True when deletion succeeded.
---@return any error Error object/message when deletion failed.
function M.delete_checked(path, flags)
    local ok, result
    if flags ~= nil then
        ok, result = pcall(vim.fn.delete, path, flags)
    else
        ok, result = pcall(vim.fn.delete, path)
    end
    if not ok then
        return false, result
    end
    if result ~= 0 then
        return false, ("delete returned %s"):format(vim.inspect(result))
    end
    return true
end

--- Recursively delete a directory only after proving plugin ownership.
---
--- This is the high-level cleanup primitive for generated directory trees.
--- Low-level callers may still use `delete_checked`, but any recursive cleanup
--- of user-configurable paths should pass through this helper so root equality,
--- containment, and ownership proof are enforced in one place.
---@param path string Directory path to delete.
---@param opts? table Ownership policy.
---@return boolean ok True when the directory was removed or did not exist.
---@return table|string|integer|nil error Error payload/message when refused or failed.
function M.delete_owned_tree(path, opts)
    return owned_path.delete_tree(path, opts)
end

--- Rename a path and normalize libuv failures.
---@param source string Source path.
---@param destination string Destination path.
---@return boolean ok True when rename succeeded.
---@return any error Error object/message when rename failed.
function M.rename_checked(source, destination)
    local ok, result, err = pcall(uv.fs_rename, source, destination)
    if not ok then
        return false, result
    end
    if result == true or result == 0 then
        return true
    end
    return false, err or result or "rename failed"
end

local function process_id()
    if uv.os_getpid then
        return uv.os_getpid()
    end
    return vim.fn.getpid()
end

local function unique_sidecar_path(parent, basename, purpose)
    for _ = 1, 100 do
        temp_counter = temp_counter + 1
        local path = path_util.join(
            parent,
            (".%s.typst-nvim-%s-%s-%s-%s"):format(
                basename,
                purpose,
                tostring(process_id()),
                tostring(uv.hrtime()),
                tostring(temp_counter)
            )
        )
        if not uv.fs_stat(path) then
            return path
        end
    end
    return nil, "failed to allocate unique temporary path"
end

local function chmod_like(path, stat)
    if not stat or not stat.mode then
        return
    end
    pcall(uv.fs_chmod, path, stat.mode)
end

local function fsync_path(path, opts)
    opts = opts or {}
    if not opts.durable then
        return true
    end
    if not uv.fs_open or not uv.fs_fsync or not uv.fs_close then
        if opts.durable == "strict" then
            return false, "fsync is not supported by this Neovim/libuv"
        end
        return true
    end

    local fd, open_err = uv.fs_open(path, "r", 438)
    if not fd then
        if opts.best_effort then
            return true
        end
        return false, open_err or ("failed to open " .. path)
    end

    local ok, result, err = pcall(uv.fs_fsync, fd)
    pcall(uv.fs_close, fd)
    if not ok then
        return false, result
    end
    if result == true or result == 0 or result == nil then
        return true
    end
    return false, err or result or ("failed to fsync " .. path)
end

local function fsync_parent(path, opts)
    opts = opts or {}
    if not opts.durable then
        return true
    end
    return fsync_path(path_util.dirname(path), {
        durable = opts.durable,
        best_effort = opts.durable ~= "strict",
    })
end

local function create_journal(parent, basename, payload, opts)
    if not (opts and opts.durable) then
        return nil, true
    end

    -- The journal is only for durable writes. It leaves enough recovery paths
    -- for callers to report what survived if replacement fails mid-flight.
    local journal, journal_err =
        unique_sidecar_path(parent, basename, "journal")
    if not journal then
        return nil, false, journal_err
    end

    local lines = {
        vim.json.encode(vim.tbl_extend("force", payload, {
            journal = journal,
            pid = process_id(),
        })),
    }
    local ok, err = M.writefile_checked(lines, journal)
    if not ok then
        return journal, false, err
    end

    ok, err = fsync_path(journal, opts)
    if not ok then
        return journal, false, err
    end

    ok, err = fsync_parent(journal, opts)
    if not ok then
        return journal, false, err
    end

    return journal, true
end

local function cleanup_journal(journal, opts)
    if not journal then
        return
    end

    M.delete_checked(journal)
    fsync_parent(journal, opts)
end

--- Atomically replace a file with optional durability guarantees.
---@param lines string[] Lines passed to `writefile` for the replacement file.
---@param path string Destination path to replace.
---@param opts? table Write options; `durable=true` fsyncs the file and parent directory.
---@return boolean ok True when the replacement was committed.
---@return table|string|nil error Error payload or message when the write failed.
function M.atomic_writefile(lines, path, opts)
    opts = opts or {}
    local parent_ok, parent_err = M.ensure_parent(path)
    if not parent_ok then
        return false, parent_err
    end
    local parent = path_util.dirname(path)
    local basename = path_util.basename(path)
    local existing_stat = uv.fs_stat(path)
    local existing_lstat = uv.fs_lstat and uv.fs_lstat(path) or existing_stat
    if existing_lstat and existing_lstat.type == "link" then
        -- Atomic replacement would replace the link itself rather than the
        -- target. Refuse it so bibliography edits cannot silently escape the
        -- project path through a symlink.
        return false,
            {
                reason = "symlink_unsupported",
                message = "refusing to atomically replace a symlink",
                original = path,
            }
    end
    local temp, temp_err = unique_sidecar_path(parent, basename, "write")
    if not temp then
        return false, temp_err
    end
    local backup, backup_err = unique_sidecar_path(parent, basename, "backup")
    if not backup then
        return false, backup_err
    end

    local journal, journal_ok, journal_err = create_journal(parent, basename, {
        operation = "atomic_writefile",
        original = path,
        temporary = temp,
        backup = backup,
    }, opts)
    if not journal_ok then
        if journal then
            M.delete_checked(journal)
        end
        return false,
            {
                reason = "journal_failed",
                error = journal_err,
                original = path,
                journal = journal,
            }
    end

    local ok, err = M.writefile_checked(lines, temp)
    if not ok then
        cleanup_journal(journal, opts)
        return false, err
    end
    ok, err = fsync_path(temp, opts)
    if not ok then
        M.delete_checked(temp)
        cleanup_journal(journal, opts)
        return false,
            {
                reason = "fsync_failed",
                error = err,
                original = path,
                temporary = temp,
                journal = journal,
            }
    end

    local renamed, rename_err = M.rename_checked(temp, path)
    if renamed then
        chmod_like(path, existing_stat)
        fsync_parent(path, opts)
        cleanup_journal(journal, opts)
        return true
    end

    if existing_stat then
        local backup_ok, backup_err = M.rename_checked(path, backup)
        if not backup_ok then
            M.delete_checked(temp)
            cleanup_journal(journal, opts)
            return false,
                backup_err or rename_err or "failed to back up existing file"
        end

        renamed, rename_err = M.rename_checked(temp, path)
        if renamed then
            chmod_like(path, existing_stat)
            M.delete_checked(backup)
            fsync_parent(path, opts)
            cleanup_journal(journal, opts)
            return true
        end

        local restored, restore_err = M.rename_checked(backup, path)
        if not restored then
            return false,
                {
                    reason = "restore_failed",
                    error = restore_err,
                    replace_error = rename_err,
                    original = path,
                    backup = backup,
                    temporary = temp,
                    journal = journal,
                    recovery = {
                        original = path,
                        backup = backup,
                        temporary = temp,
                        journal = journal,
                    },
                }
        end
    end

    M.delete_checked(temp)
    cleanup_journal(journal, opts)
    return false, rename_err or "failed to rename temporary file"
end

return M
