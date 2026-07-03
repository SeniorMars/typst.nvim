local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local lock_helper = require("tests.helpers.output_locks")
local outputs = require("typst.resources.outputs")
local typst = require("typst")

local uv = vim.uv or vim.loop

typst.reset({ force = true })
outputs.reset()
lock_helper.reset_lock_dir()

local base = lock_helper.base_dir("output-locks-policy")
local grace = outputs._incomplete_lock_grace_seconds()

local active_output = lock_helper.path(base, "active-current.pdf")
local active_lease =
    assert(outputs.acquire(active_output, { kind = "active-current" }))
local active_record = assert(outputs.locks({ path = active_output })[1])
assert(
    active_record.active_current == true
        and active_record.recoverable == false
        and active_record.lock_status == "current_process",
    "current-process active locks should not be recoverable"
)
local active_clean = outputs.clean_locks({
    path = active_output,
    force = true,
})
assert(
    active_clean.skipped == 1
        and active_clean.locks[1].reason == "current_process",
    "forced cleanup should not remove current-process active locks"
)
outputs.release(active_lease)

local dead_output = lock_helper.path(base, "dead-owner.pdf")
local dead_lock_path = lock_helper.write_owner(dead_output, {
    pid = 999999999,
    path = dead_output,
    owner = { kind = "dead-owner" },
})
local dead_record = assert(outputs.locks({ path = dead_output })[1])
assert(
    dead_record.recoverable == true and dead_record.lock_status == "dead_owner",
    "dead-owner locks should be immediately recoverable"
)
local dead_clean = outputs.clean_locks({ path = dead_output })
assert(
    dead_clean.removed == 1 and vim.fn.isdirectory(dead_lock_path) == 0,
    "normal cleanup should remove dead-owner locks"
)

local fresh_empty_output = lock_helper.path(base, "fresh-empty.pdf")
local fresh_empty_lock_path =
    lock_helper.write_raw_owner(fresh_empty_output, {})
local fresh_empty_record =
    assert(outputs.locks({ path = fresh_empty_lock_path })[1])
assert(
    fresh_empty_record.recoverable == false
        and fresh_empty_record.owner_status == "empty"
        and fresh_empty_record.lock_status == "empty",
    "fresh incomplete owner records should stay protected during grace"
)
local fresh_empty_lease, fresh_empty_err =
    outputs.acquire(fresh_empty_output, { kind = "fresh-empty-contender" })
assert(
    not fresh_empty_lease
        and fresh_empty_err
        and fresh_empty_err.lock_status == "empty",
    "fresh incomplete owner records should block acquisition"
)
vim.fn.delete(outputs._lock_path(fresh_empty_output), "rf")

local old_empty_output = lock_helper.path(base, "old-empty.pdf")
local old_empty_lock_path = lock_helper.write_raw_owner(old_empty_output, {})
lock_helper.age_owner(old_empty_output, grace + 5)
local old_empty_record =
    assert(outputs.locks({ path = old_empty_lock_path })[1])
assert(
    old_empty_record.recoverable == true
        and old_empty_record.lock_status == "empty",
    "old incomplete owner records should be recoverable after grace"
)
local old_empty_clean = outputs.clean_locks({ path = old_empty_lock_path })
assert(
    old_empty_clean.removed == 1
        and vim.fn.isdirectory(old_empty_lock_path) == 0,
    "normal cleanup should remove old incomplete locks"
)

local fresh_corrupt_output = lock_helper.path(base, "fresh-corrupt.pdf")
local fresh_corrupt_lock_path =
    lock_helper.write_raw_owner(fresh_corrupt_output, { "{" })
local fresh_corrupt_record =
    assert(outputs.locks({ path = fresh_corrupt_lock_path })[1])
assert(
    fresh_corrupt_record.recoverable == false
        and fresh_corrupt_record.owner_status == "corrupt"
        and fresh_corrupt_record.lock_status == "corrupt",
    "fresh corrupt owner records should stay protected during grace"
)
local unfiltered_force = outputs.clean_locks({ force = true })
assert(
    unfiltered_force.skipped >= 1
        and vim.fn.isdirectory(fresh_corrupt_lock_path) == 1,
    "forced cleanup should require a filter for unknown external locks"
)
local filtered_force = outputs.clean_locks({
    path = fresh_corrupt_lock_path,
    force = true,
})
assert(
    filtered_force.removed == 1
        and vim.fn.isdirectory(fresh_corrupt_lock_path) == 0,
    "forced filtered cleanup should remove unknown external locks"
)

local live_pid = uv.os_getppid and uv.os_getppid() or nil
if live_pid and live_pid > 0 then
    local live_output = lock_helper.path(base, "live-pid.pdf")
    local live_lock_path = lock_helper.write_owner(live_output, {
        pid = live_pid,
        path = live_output,
        created_at = os.time() - grace - 5,
        owner = { kind = "live-owner" },
    })
    local live_record = assert(outputs.locks({ path = live_output })[1])
    assert(
        live_record.recoverable == false
            and live_record.lock_status == "old_live_pid",
        "live-PID locks should not be stolen by age"
    )
    local live_clean = outputs.clean_locks({ path = live_output })
    assert(
        live_clean.skipped == 1 and vim.fn.isdirectory(live_lock_path) == 1,
        "normal cleanup should keep live foreign PID locks"
    )
    vim.fn.delete(live_lock_path, "rf")
end

outputs.reset()
lock_helper.reset_lock_dir()
vim.cmd("qa!")
