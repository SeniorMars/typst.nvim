local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local outputs = require("typst.resources.outputs")
local log = require("typst.core.log")
local typst = require("typst")
local uv = vim.uv or vim.loop

typst.reset()
outputs.reset()

local base = typst_test_cache_path("output-locks")
vim.fn.delete(base, "rf")
vim.fn.mkdir(base, "p")

local output = base .. "/main.pdf"
vim.fn.mkdir(vim.fn.fnamemodify(output, ":h"), "p")

local lease = assert(outputs.acquire(output, { kind = "lock-test" }))
assert(lease.lock_path, "output lease should include a file-backed lock path")
assert(
    vim.fn.isdirectory(lease.lock_path) == 1,
    "output lock directory should be created on acquire"
)
local lock = outputs._read_lock(output)
assert(lock and lock.path == output, "output lock should record active path")
assert(
    lock.owner and lock.owner.kind == "lock-test",
    "output lock should record owner metadata"
)
assert(outputs.release(lease), "output lease should release")
assert(
    vim.fn.isdirectory(lease.lock_path) == 0,
    "output lock directory should be removed on release"
)

local stale_output = base .. "/stale.pdf"
local stale_lock_path = outputs._lock_path(stale_output)
vim.fn.mkdir(stale_lock_path, "p")
vim.fn.writefile({
    vim.json.encode({
        pid = 999999999,
        path = stale_output,
        owner = { kind = "stale-lock" },
    }),
}, outputs._owner_path(stale_output))
local stale_lease =
    assert(outputs.acquire(stale_output, { kind = "stale-lock-recovered" }))
local stale_lock = outputs._read_lock(stale_output)
assert(
    stale_lock.owner.kind == "stale-lock-recovered",
    "stale output lock should be replaced by the new owner"
)
outputs.release(stale_lease)

local corrupt_output = base .. "/corrupt.pdf"
local corrupt_lock_path = outputs._lock_path(corrupt_output)
vim.fn.mkdir(corrupt_lock_path, "p")
vim.fn.writefile({ "{" }, outputs._owner_path(corrupt_output))
local corrupt_lease, corrupt_err =
    outputs.acquire(corrupt_output, { kind = "corrupt-lock-contender" })
assert(not corrupt_lease, "corrupt active lock should block acquisition")
assert(
    corrupt_err
        and corrupt_err.reason == "active_output"
        and corrupt_err.lock_status == "corrupt",
    "corrupt active lock should be reported as an active external lock"
)
vim.fn.delete(corrupt_lock_path, "rf")

local empty_output = base .. "/empty-owner.pdf"
local empty_lock_path = outputs._lock_path(empty_output)
vim.fn.mkdir(empty_lock_path, "p")
vim.fn.writefile({}, outputs._owner_path(empty_output))
local empty_lease, empty_err =
    outputs.acquire(empty_output, { kind = "empty-lock-contender" })
assert(not empty_lease, "fresh empty owner record should block acquisition")
assert(
    empty_err
        and empty_err.reason == "active_output"
        and empty_err.lock_status == "empty",
    "fresh empty owner record should be reported as an active external lock"
)
vim.fn.delete(empty_lock_path, "rf")

local old_empty_output = base .. "/old-empty-owner.pdf"
local old_empty_lock_path = outputs._lock_path(old_empty_output)
vim.fn.mkdir(old_empty_lock_path, "p")
local old_empty_owner_path = outputs._owner_path(old_empty_output)
vim.fn.writefile({}, old_empty_owner_path)
local old_time = os.time() - outputs._incomplete_lock_grace_seconds() - 5
local utime_ok, utime_result, utime_err =
    pcall(uv.fs_utime, old_empty_owner_path, old_time, old_time)
assert(
    utime_ok and utime_result ~= nil,
    "test fixture should be able to age an incomplete owner record"
        .. tostring(utime_err and (": " .. utime_err) or "")
)
local old_empty_lease =
    assert(outputs.acquire(old_empty_output, { kind = "old-empty-recovered" }))
local old_empty_lock = outputs._read_lock(old_empty_output)
assert(
    old_empty_lock.owner.kind == "old-empty-recovered",
    "old incomplete owner record should be recovered after the short grace"
)
outputs.release(old_empty_lease)

local live_pid = uv.os_getppid and uv.os_getppid() or nil
if live_pid and live_pid > 0 then
    local reused_pid_output = base .. "/reused-pid.pdf"
    local reused_pid_lock_path = outputs._lock_path(reused_pid_output)
    vim.fn.mkdir(reused_pid_lock_path, "p")
    vim.fn.writefile({
        vim.json.encode({
            pid = live_pid,
            path = reused_pid_output,
            created_at = os.time() - outputs._stale_lock_ttl_seconds() - 10,
            owner = { kind = "old-live-pid" },
        }),
    }, outputs._owner_path(reused_pid_output))
    local reused_pid_lease, reused_pid_err =
        outputs.acquire(reused_pid_output, { kind = "old-live-pid-contender" })
    assert(
        not reused_pid_lease,
        "old lock owned by a live PID should not be auto-recovered"
    )
    assert(
        reused_pid_err
            and reused_pid_err.reason == "active_output"
            and reused_pid_err.lock_status == "old_live_pid",
        "old live-PID lock should report that the owner is still live"
    )
    vim.fn.delete(reused_pid_lock_path, "rf")
end

local release_fail_output = base .. "/release-failure.pdf"
local release_fail_lease = assert(outputs.acquire(release_fail_output, {
    kind = "release-failure",
    project_key = "project-a",
}))
log.clear()
vim.fn.writefile({
    vim.json.encode({
        pid = 999999999,
        path = release_fail_output,
        owner = { kind = "foreign-owner" },
    }),
}, outputs._owner_path(release_fail_output))
assert(
    outputs.release(release_fail_lease),
    "in-process lease should still release when lock cleanup fails"
)
local last_failure = outputs.last_release_failure()
assert(
    last_failure
        and last_failure.path == release_fail_output
        and last_failure.error == "foreign_lock_owner"
        and last_failure.context == "release",
    "output lock release failures should be retained for status reports"
)
assert(
    outputs.last_release_failure({ key = "project-a" }) ~= nil,
    "matching projects should see their output lock release failure"
)
assert(
    outputs.last_release_failure({ key = "project-b" }) == nil,
    "unrelated projects should not see another project's output lock release failure"
)
local saw_release_warning = false
for _, entry in ipairs(log.entries()) do
    if entry.message == "failed to release output lock" then
        saw_release_warning = true
        break
    end
end
assert(saw_release_warning, "failed output lock cleanup should be logged")
vim.fn.delete(release_fail_lease.lock_path, "rf")

local corrupt_release_output = base .. "/corrupt-release.pdf"
local corrupt_release_lease = assert(outputs.acquire(corrupt_release_output, {
    kind = "corrupt-release",
}))
vim.fn.writefile({ "{" }, outputs._owner_path(corrupt_release_output))
assert(
    outputs.release(corrupt_release_lease),
    "in-process lease should release even when owner metadata is corrupt"
)
assert(
    vim.fn.isdirectory(corrupt_release_lease.lock_path) == 1,
    "release should not delete corrupt or unreadable owner metadata"
)
local corrupt_release_failure = outputs.last_release_failure()
assert(
    corrupt_release_failure and corrupt_release_failure.error == "corrupt",
    "corrupt release owner metadata should be reported as a lock release failure"
)
assert(
    outputs.last_release_failure({ key = "project-a" }) == nil,
    "unscoped release failures should not appear in project-scoped reports"
)
vim.fn.delete(corrupt_release_lease.lock_path, "rf")

local clean_stale_output = base .. "/clean-stale.pdf"
local clean_stale_lock_path = outputs._lock_path(clean_stale_output)
vim.fn.mkdir(clean_stale_lock_path, "p")
vim.fn.writefile({
    vim.json.encode({
        pid = 999999999,
        path = clean_stale_output,
        owner = { kind = "clean-stale" },
    }),
}, outputs._owner_path(clean_stale_output))
local listed_stale = outputs.locks({ path = clean_stale_output })
assert(
    listed_stale[1] and listed_stale[1].recoverable,
    "dead-owner lock should be listed as cleanable"
)
local cleaned_stale = outputs.clean_locks({ path = clean_stale_output })
assert(
    cleaned_stale.removed == 1 and cleaned_stale.failed == 0,
    "default lock cleanup should remove dead-owner locks"
)
assert(
    vim.fn.isdirectory(clean_stale_lock_path) == 0,
    "default cleanup should delete the stale lock directory"
)

local clean_corrupt_output = base .. "/clean-corrupt.pdf"
local clean_corrupt_lock_path = outputs._lock_path(clean_corrupt_output)
vim.fn.mkdir(clean_corrupt_lock_path, "p")
vim.fn.writefile({ "{" }, outputs._owner_path(clean_corrupt_output))
local skipped_corrupt = outputs.clean_locks({ path = clean_corrupt_lock_path })
assert(
    skipped_corrupt.skipped == 1
        and vim.fn.isdirectory(clean_corrupt_lock_path) == 1,
    "default lock cleanup should keep fresh corrupt owner records"
)
local unfiltered_force_corrupt = outputs.clean_locks({ force = true })
assert(
    unfiltered_force_corrupt.skipped == 1
        and unfiltered_force_corrupt.locks[1].reason == "force_requires_filter"
        and vim.fn.isdirectory(clean_corrupt_lock_path) == 1,
    "forced lock cleanup should require an explicit filter for unknown external locks"
)
local force_cleaned_corrupt = outputs.clean_locks({
    path = clean_corrupt_lock_path,
    force = true,
})
assert(
    force_cleaned_corrupt.removed == 1
        and vim.fn.isdirectory(clean_corrupt_lock_path) == 0,
    "forced lock cleanup should remove unknown external locks"
)

local active_clean_output = base .. "/clean-active.pdf"
local active_clean_lease =
    assert(outputs.acquire(active_clean_output, { kind = "clean-active" }))
local active_cleaned = outputs.clean_locks({
    path = active_clean_output,
    force = true,
})
assert(
    active_cleaned.skipped == 1
        and vim.fn.isdirectory(active_clean_lease.lock_path) == 1,
    "forced lock cleanup should not remove current-process active locks"
)
outputs.release(active_clean_lease)

local reset_output = base .. "/reset.pdf"
local reset_lease = assert(outputs.acquire(reset_output, { kind = "reset" }))
assert(
    vim.fn.isdirectory(reset_lease.lock_path) == 1,
    "reset fixture should create an output lock"
)
outputs.reset()
assert(
    vim.fn.isdirectory(reset_lease.lock_path) == 0,
    "outputs.reset should remove this process's output locks"
)

vim.cmd("qa!")
