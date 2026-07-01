local log = require("typst.core.log")
local path_leases = require("typst.core.path_leases")
local path_util = require("typst.core.path")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop
local STALE_LOCK_TTL_SECONDS = 7 * 24 * 60 * 60
local INCOMPLETE_LOCK_GRACE_SECONDS = 30
local last_release_failure = nil

-- Project-scoped output ownership facade.
--
-- Low-level lease storage lives in core.path_leases. This module is the
-- compile/render/export-facing boundary so generated output ownership can be
-- reported and migrated without each workflow knowing lease internals.
--
-- File-backed lock records extend the in-process lease table across Neovim
-- instances. They are best-effort coordination, not a replacement for provider
-- stop confirmation: retained unconfirmed handles still keep their in-process
-- lease until force-cleared or confirmed stopped.

local function lock_dir()
    return vim.fs.joinpath(vim.fn.stdpath("cache"), "typst.nvim", "locks")
end

local function lock_key(path)
    return path_util.path_key(path_util.canonical(path))
end

local function lock_path_for(path)
    return vim.fs.joinpath(
        lock_dir(),
        vim.fn.sha256(lock_key(path)) .. ".lockdir"
    )
end

local function owner_path_for(lock_path)
    return vim.fs.joinpath(lock_path, "owner.json")
end

local function read_lock(path)
    local stat = uv.fs_stat(path)
    if not stat then
        return nil, "missing", nil
    end

    local owner_path = stat.type == "directory" and owner_path_for(path) or path
    local fd = uv.fs_open(owner_path, "r", 438)
    if not fd then
        return nil, "unreadable", stat
    end
    local owner_stat = uv.fs_fstat(fd)
    local body = owner_stat and uv.fs_read(fd, owner_stat.size, 0) or nil
    uv.fs_close(fd)
    if not body or body == "" then
        return nil, "empty", owner_stat or stat
    end
    local ok, decoded = pcall(vim.json.decode, body)
    if ok and type(decoded) == "table" then
        return decoded, "ok", stat
    end
    return nil, "corrupt", owner_stat or stat
end

local function pid_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then
        return false
    end
    if pid == uv.os_getpid() then
        return false
    end
    local ok, err = uv.kill(pid, 0)
    return ok == true or ok == 0 or err == "EPERM"
end

local function lock_age_seconds(lock, stat)
    local created_at = type(lock) == "table" and tonumber(lock.created_at)
        or nil
    if created_at then
        return math.max(0, os.time() - created_at)
    end
    local mtime = stat and stat.mtime and stat.mtime.sec
    if mtime then
        return math.max(0, os.time() - mtime)
    end
    return 0
end

local function lock_recoverable(lock, status, stat)
    local age = lock_age_seconds(lock, stat)
    if type(lock) ~= "table" or tonumber(lock.pid) == nil then
        return age > INCOMPLETE_LOCK_GRACE_SECONDS, status or "incomplete"
    end
    if pid_alive(lock.pid) then
        return false, "old_live_pid"
    end
    return true, "dead_owner"
end

local function remove_lock_path(path)
    local stat = uv.fs_stat(path)
    if not stat then
        return true
    end
    if stat.type == "directory" then
        pcall(uv.fs_unlink, owner_path_for(path))
        local ok, removed = pcall(uv.fs_rmdir, path)
        return ok and removed ~= false and removed ~= nil
    end
    local ok, removed = pcall(uv.fs_unlink, path)
    return ok and removed ~= false and removed ~= nil
end

local function active_lock_paths()
    local active = {}
    for _, lease in pairs(path_leases.active()) do
        if type(lease.lock_path) == "string" then
            active[lease.lock_path] = true
        end
    end
    return active
end

local function lock_record(lock_path, active_paths)
    local lock, status, stat = read_lock(lock_path)
    local active_current = active_paths and active_paths[lock_path] or false
    local recoverable, recover_status = lock_recoverable(lock, status, stat)
    if active_current then
        recoverable = false
        recover_status = "current_process"
    end

    return {
        lock_path = lock_path,
        owner_path = owner_path_for(lock_path),
        path = lock and lock.path or nil,
        key = lock and lock.key or nil,
        owner = vim.deepcopy(lock and lock.owner or {}),
        pid = lock and lock.pid or nil,
        age_seconds = lock_age_seconds(lock, stat),
        owner_status = status,
        lock_status = recover_status,
        recoverable = recoverable,
        active_current = active_current,
    }
end

local function lock_matches(record, target)
    if type(target) ~= "string" or target == "" then
        return true
    end
    local normalized = path_util.normalize(target)
    local target_key = normalized and lock_key(normalized) or target
    return record.path == target
        or record.lock_path == target
        or record.owner_path == target
        or record.key == target_key
end

local function lock_error(path, lock_path, lock, status)
    local live_owner = status == "old_live_pid"
    return {
        ok = false,
        reason = "active_output",
        message = live_owner
                and "Output path is locked by a live typst.nvim owner; use :TypstLocks to inspect it and :TypstCleanLocks! only if the owner is gone"
            or lock and "Output path is already being written by another typst.nvim session"
            or "Output path lock exists but owner metadata is not readable yet",
        path = path,
        active_output = lock and lock.path or path,
        owner = lock and lock.owner or nil,
        lock_path = lock_path,
        external_lock = true,
        pid = lock and lock.pid or nil,
        lock_status = status,
    }
end

local function write_lock(path, owner)
    local dir = lock_dir()
    local mkdir_ok = vim.fn.mkdir(dir, "p")
    if mkdir_ok ~= 1 and vim.fn.isdirectory(dir) ~= 1 then
        return nil,
            {
                ok = false,
                reason = "lock_parent_create_failed",
                message = "failed to create output lock directory",
                path = path,
            }
    end

    local lock_path = lock_path_for(path)
    local ok_mkdir, mkdir_err = uv.fs_mkdir(lock_path, 448)
    if not ok_mkdir then
        local existing, status, stat = read_lock(lock_path)
        local recoverable, recovery_status =
            lock_recoverable(existing, status, stat)
        if not recoverable then
            return nil, lock_error(path, lock_path, existing, recovery_status)
        end
        if not remove_lock_path(lock_path) then
            return nil,
                {
                    ok = false,
                    reason = "lock_recovery_failed",
                    message = "failed to remove stale output lock",
                    path = path,
                    lock_path = lock_path,
                    lock_status = recovery_status,
                }
        end
        log.add("warn", "recovered stale output lock", {
            path = path,
            lock_path = lock_path,
            lock_status = recovery_status,
            age_seconds = lock_age_seconds(existing, stat),
        })
        ok_mkdir, mkdir_err = uv.fs_mkdir(lock_path, 448)
    end
    if not ok_mkdir then
        local existing, status = read_lock(lock_path)
        return nil, lock_error(path, lock_path, existing, status or mkdir_err)
    end

    local payload = vim.json.encode({
        pid = uv.os_getpid(),
        path = path,
        key = lock_key(path),
        owner = owner or {},
        created_at = os.time(),
    })
    local owner_path = owner_path_for(lock_path)
    local fd, open_err = uv.fs_open(owner_path, "w", 420)
    if not fd then
        remove_lock_path(lock_path)
        return nil,
            {
                ok = false,
                reason = "lock_write_failed",
                message = tostring(
                    open_err or "failed to open lock owner record"
                ),
                path = path,
                lock_path = lock_path,
            }
    end
    local ok, written, write_err = pcall(uv.fs_write, fd, payload, 0)
    uv.fs_close(fd)
    if not ok or written ~= #payload then
        remove_lock_path(lock_path)
        return nil,
            {
                ok = false,
                reason = "lock_write_failed",
                message = tostring(
                    (not ok and written)
                        or write_err
                        or ("partial write: " .. tostring(written))
                ),
                path = path,
                lock_path = lock_path,
            }
    end
    return lock_path
end

local function release_lock(lease)
    if type(lease) ~= "table" or type(lease.lock_path) ~= "string" then
        return true
    end
    local lock, status = read_lock(lease.lock_path)
    if not lock and not uv.fs_stat(lease.lock_path) then
        return true
    end
    if not lock then
        return false, status or "unreadable_lock_owner"
    end
    if lock and tonumber(lock.pid) ~= uv.os_getpid() then
        return false, "foreign_lock_owner"
    end
    if remove_lock_path(lease.lock_path) then
        return true
    end
    return false, "remove_failed"
end

local function record_release_failure(lease, err, context)
    last_release_failure = {
        path = lease and lease.path or nil,
        lock_path = lease and lease.lock_path or nil,
        owner = vim.deepcopy(lease and lease.owner or {}),
        project_key = lease and lease.owner and lease.owner.project_key or nil,
        error = err,
        context = context,
        at = os.time(),
    }
    log.add(
        "warn",
        context == "reset" and "failed to release output lock during reset"
            or "failed to release output lock",
        last_release_failure
    )
end

function M.owner(kind, project, fields)
    return vim.tbl_extend("force", {
        kind = kind,
        project_key = project and project.key or nil,
        main = project and project.main or nil,
    }, fields or {})
end

function M.ensure_parent(path)
    return util.ensure_parent(path)
end

function M.lock_dir()
    return lock_dir()
end

function M.acquire(path, owner)
    local lease, err = path_leases.acquire(path, owner)
    if not lease then
        return nil, err
    end

    local lock_path, lock_err = write_lock(path, owner)
    if not lock_path then
        path_leases.release(lease)
        return nil, lock_err
    end
    lease.lock_path = lock_path
    return lease
end

function M.acquire_many(items, owner)
    local leases, err = path_leases.acquire_many(items, owner)
    if not leases then
        return nil, err
    end

    for _, lease in ipairs(leases) do
        local lock_path, lock_err = write_lock(lease.path, owner)
        if not lock_path then
            M.release_many(leases)
            return nil, lock_err
        end
        lease.lock_path = lock_path
    end
    return leases
end

function M.release(lease)
    local released = path_leases.release(lease)
    if released then
        local lock_released, lock_err = release_lock(lease)
        if not lock_released then
            record_release_failure(lease, lock_err, "release")
        end
    end
    return released
end

function M.release_many(leases)
    for _, lease in ipairs(leases or {}) do
        M.release(lease)
    end
end

function M.active(path)
    return path_leases.active(path)
end

function M.active_for_project(project)
    local out = {}
    local key = project and project.key
    for lease_key, lease in pairs(path_leases.active()) do
        if lease.owner and lease.owner.project_key == key then
            out[lease_key] = lease
        end
    end
    return out
end

function M.snapshot(project)
    local out = {}
    for lease_key, lease in pairs(M.active_for_project(project)) do
        out[#out + 1] = {
            key = lease_key,
            path = lease.path,
            owner = vim.deepcopy(lease.owner or {}),
            lock_path = lease.lock_path,
        }
    end
    table.sort(out, function(left, right)
        return (left.path or left.key or "") < (right.path or right.key or "")
    end)
    return out
end

function M.locks(opts)
    opts = opts or {}
    local dir = lock_dir()
    local paths = vim.fn.globpath(dir, "*.lockdir", false, true)
    table.sort(paths)
    local active_paths = active_lock_paths()
    local out = {}
    for _, lock_path in ipairs(paths) do
        local record = lock_record(lock_path, active_paths)
        if lock_matches(record, opts.path) then
            out[#out + 1] = record
        end
    end
    return out
end

function M.clean_locks(opts)
    opts = opts or {}
    local force = opts.force == true
    local has_filter = type(opts.path) == "string" and opts.path ~= ""
    local result = {
        ok = true,
        removed = 0,
        skipped = 0,
        failed = 0,
        locks = {},
    }
    for _, record in ipairs(M.locks({ path = opts.path })) do
        local removable = record.recoverable
            or (force and has_filter and not record.active_current)
        if not removable then
            result.skipped = result.skipped + 1
            result.locks[#result.locks + 1] = vim.tbl_extend("force", record, {
                cleaned = false,
                reason = record.active_current and "current_process"
                    or force and not has_filter and "force_requires_filter"
                    or "active_or_unknown_owner",
            })
        elseif remove_lock_path(record.lock_path) then
            result.removed = result.removed + 1
            result.locks[#result.locks + 1] = vim.tbl_extend("force", record, {
                cleaned = true,
            })
        else
            result.ok = false
            result.failed = result.failed + 1
            result.locks[#result.locks + 1] = vim.tbl_extend("force", record, {
                cleaned = false,
                reason = "remove_failed",
            })
        end
    end
    return result
end

function M.reset()
    local failed = false
    for _, lease in pairs(path_leases.active()) do
        local released, err = release_lock(lease)
        if not released then
            failed = true
            record_release_failure(lease, err, "reset")
        end
    end
    local reset = path_leases.reset()
    if not failed then
        last_release_failure = nil
    end
    return reset
end

function M.last_release_failure(project)
    if
        project
        and last_release_failure
        and (
            not last_release_failure.project_key
            or last_release_failure.project_key ~= project.key
        )
    then
        return nil
    end
    return vim.deepcopy(last_release_failure)
end

function M._clear_last_release_failure()
    last_release_failure = nil
end

function M._lock_path(path)
    return lock_path_for(path)
end

function M._owner_path(path)
    return owner_path_for(lock_path_for(path))
end

function M._read_lock(path)
    return read_lock(lock_path_for(path))
end

function M._stale_lock_ttl_seconds()
    return STALE_LOCK_TTL_SECONDS
end

function M._incomplete_lock_grace_seconds()
    return INCOMPLETE_LOCK_GRACE_SECONDS
end

return M
