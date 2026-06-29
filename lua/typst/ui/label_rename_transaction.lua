local M = {}

-- Multi-file transaction for label rename.
--
-- Disk files are committed before buffers because disk writes can fail after
-- staging; buffers can still be rolled back in memory if a later file fails.
local uv = vim.uv or vim.loop

local function same_lines(left, right)
    if #left ~= #right then
        return false
    end

    for index_, line in ipairs(left) do
        if right[index_] ~= line then
            return false
        end
    end
    return true
end

local function write_temp_file(prepared)
    if not prepared.temp_path then
        return nil, "temp_path_failed"
    end

    local ok, err = require("typst.core.util").writefile_checked(
        prepared.lines,
        prepared.temp_path
    )
    if not ok then
        return nil, "temp_write_failed", err
    end
    return true
end

local function rename_path(source, destination)
    local called, ok, err = pcall(uv.fs_rename, source, destination)
    if not called then
        return nil, ok
    end
    if ok then
        return true
    end
    return nil, err or "rename_failed"
end

local function remove_file(path)
    if path and uv.fs_stat(path) then
        pcall(uv.fs_unlink, path)
    end
end

local function remove_path(path)
    if not path or not uv.fs_stat(path) then
        return true
    end

    local called, ok, err = pcall(uv.fs_unlink, path)
    if not called then
        return nil, ok
    end
    if ok then
        return true
    end
    return nil, err or "unlink_failed"
end

local function recovery_paths(prepared)
    return {
        original = prepared.path,
        backup = prepared.backup_path,
        temporary = prepared.temp_path,
    }
end

local function rollback_disk_file(prepared)
    if prepared.backup_path and uv.fs_stat(prepared.backup_path) then
        local removed, remove_err = remove_path(prepared.path)
        if not removed then
            return nil,
                "restore_remove_failed",
                remove_err,
                recovery_paths(prepared)
        end

        local restored, restore_err =
            rename_path(prepared.backup_path, prepared.path)
        if not restored then
            return nil, "restore_failed", restore_err, recovery_paths(prepared)
        end
    end
    remove_file(prepared.temp_path)
    return true
end

local function commit_disk_file(prepared)
    -- Move the original aside before replacement so a failed final rename can
    -- restore the exact bytes that were on disk.
    local ok, err = rename_path(prepared.path, prepared.backup_path)
    if not ok then
        return nil, "backup_failed", err, recovery_paths(prepared)
    end

    ok, err = rename_path(prepared.temp_path, prepared.path)
    if not ok then
        local restored, restore_err =
            rename_path(prepared.backup_path, prepared.path)
        if not restored then
            return nil,
                "write_failed",
                err,
                vim.tbl_extend("force", recovery_paths(prepared), {
                    restore_error = restore_err,
                })
        end
        return nil, "write_failed", err
    end

    return true
end

local function apply_buffer_file(prepared)
    if
        not vim.api.nvim_buf_is_valid(prepared.bufnr)
        or not vim.api.nvim_buf_is_loaded(prepared.bufnr)
    then
        return nil, "buffer_unloaded"
    end
    if not vim.bo[prepared.bufnr].modifiable then
        return nil, "buffer_not_modifiable"
    end

    local ok, current =
        pcall(vim.api.nvim_buf_get_lines, prepared.bufnr, 0, -1, false)
    if
        not ok
        or type(current) ~= "table"
        or not same_lines(current, prepared.original_lines)
    then
        return nil, "stale_source"
    end

    ok = pcall(
        vim.api.nvim_buf_set_lines,
        prepared.bufnr,
        0,
        -1,
        false,
        prepared.lines
    )
    if not ok then
        return nil, "buffer_apply_failed"
    end
    return true
end

local function rollback_buffer_file(prepared)
    if
        prepared.bufnr
        and vim.api.nvim_buf_is_valid(prepared.bufnr)
        and vim.api.nvim_buf_is_loaded(prepared.bufnr)
    then
        local modifiable = vim.bo[prepared.bufnr].modifiable
        if not modifiable then
            pcall(function()
                vim.bo[prepared.bufnr].modifiable = true
            end)
        end
        pcall(
            vim.api.nvim_buf_set_lines,
            prepared.bufnr,
            0,
            -1,
            false,
            prepared.original_lines
        )
        pcall(function()
            vim.bo[prepared.bufnr].modified = prepared.modified
            vim.bo[prepared.bufnr].modifiable = modifiable
        end)
    end
end

local function cleanup_committed_files(committed_disk)
    for _, prepared in ipairs(committed_disk) do
        remove_file(prepared.backup_path)
    end
end

local function rollback_prepared_files(committed_disk, committed_buffers)
    local failures = {}
    for index_ = #committed_buffers, 1, -1 do
        rollback_buffer_file(committed_buffers[index_])
    end
    for index_ = #committed_disk, 1, -1 do
        local ok, reason, message, recovery =
            rollback_disk_file(committed_disk[index_])
        if not ok then
            failures[#failures + 1] = {
                path = committed_disk[index_].path,
                reason = reason,
                message = message,
                recovery = recovery,
            }
        end
    end
    return failures
end

function M.apply(prepared)
    local disk_files = {}
    local buffer_files = {}
    for _, file in ipairs(prepared) do
        if file.bufnr then
            buffer_files[#buffer_files + 1] = file
        else
            disk_files[#disk_files + 1] = file
        end
    end

    -- Stage every unloaded file before mutating any destination; early
    -- validation/write failures remain side-effect free.
    for _, file in ipairs(disk_files) do
        local ok, reason = write_temp_file(file)
        if not ok then
            for _, cleanup in ipairs(disk_files) do
                remove_file(cleanup.temp_path)
            end
            return nil,
                {
                    path = file.path,
                    reason = reason,
                }
        end
    end

    local committed_disk = {}
    local committed_buffers = {}
    for _, file in ipairs(disk_files) do
        local ok, reason, message, recovery = commit_disk_file(file)
        if not ok then
            local rollback_failures =
                rollback_prepared_files(committed_disk, committed_buffers)
            if not recovery then
                for _, cleanup in ipairs(disk_files) do
                    remove_file(cleanup.temp_path)
                end
            end
            return nil,
                {
                    path = file.path,
                    reason = reason,
                    message = message,
                    recovery = recovery,
                    rollback_failures = rollback_failures,
                }
        end
        committed_disk[#committed_disk + 1] = file
    end

    -- Buffers are last so disk rollback remains possible if a buffer changed
    -- between planning and apply.
    for _, file in ipairs(buffer_files) do
        local ok, reason = apply_buffer_file(file)
        if not ok then
            local rollback_failures =
                rollback_prepared_files(committed_disk, committed_buffers)
            return nil,
                {
                    path = file.path,
                    reason = reason,
                    rollback_failures = rollback_failures,
                    recovery = rollback_failures[1]
                            and rollback_failures[1].recovery
                        or nil,
                }
        end
        committed_buffers[#committed_buffers + 1] = file
    end

    cleanup_committed_files(committed_disk)
    return true
end

return M
