local state = require("typst.preview.state_machine")
local preview_service = require("typst.project.services.preview")

local project = {
    key = "preview-state-machine",
    root = "/tmp",
    main = "/tmp/main.typ",
    services = {},
}

local handle = { pending = true }
local generation = state.next_generation()
state.to_opening(project, { mode = "slide" }, handle, generation, {
    kind = "test",
})

local preview = preview_service.get(project)
assert(preview.opening == true, "to_opening should mark opening")
assert(preview.active == false, "to_opening should clear active")
assert(preview.open_handle == handle, "to_opening should store open handle")
assert(
    preview.open_generation == generation,
    "to_opening should store generation"
)
assert(
    state.pending_open_current(project, handle, generation, nil),
    "pending_open_current should accept matching handle/generation/token"
)

state.to_open_cancel_unconfirmed(project, {
    ok = false,
    reason = "cancel_pending",
}, "open_cancel_pending")
preview = preview_service.get(project)
assert(preview.opening == true, "unconfirmed cancel should retain opening")
assert(preview.stopping == true, "unconfirmed cancel should mark stopping")
assert(
    preview.status == "open_cancel_pending",
    "unconfirmed cancel should record status"
)

state.clear_pending_open(project, { ok = true, stopped = true })
preview = preview_service.get(project)
assert(preview.opening == false, "clear_pending_open should clear opening")
assert(preview.open_handle == nil, "clear_pending_open should clear handle")
assert(preview.active == false, "clear_pending_open should leave inactive")

state.to_open_failed(project, { ok = false, reason = "browser_failed" })
preview = preview_service.get(project)
assert(preview.active == false, "to_open_failed should clear active")
assert(preview.opening == false, "to_open_failed should clear opening")
assert(preview.status == "open_failed", "to_open_failed should set status")
assert(
    preview.last_error == "browser_failed",
    "to_open_failed should record reason as last_error"
)

state.to_stop_unconfirmed(project, { pending = true }, "reset")
preview = preview_service.get(project)
assert(preview.active == true, "unconfirmed stop should preserve active")
assert(preview.stopping == true, "unconfirmed stop should mark stopping")
assert(
    preview.stop_prune_reason == "reset",
    "unconfirmed stop should record lifecycle reason"
)

state.to_stopping_failed(project, { ok = false, reason = "stop_failed" })
preview = preview_service.get(project)
assert(preview.active == true, "stop failure should preserve active")
assert(preview.stopping == false, "stop failure should clear stopping")
assert(
    preview.status == "stopping_failed",
    "stop failure should mark stopping_failed"
)

local stopped_event_saw_result = false
local stopped_event_saw_inactive = false
local event_project = {
    key = "preview-state-machine-event",
    root = "/tmp",
    main = "/tmp/event.typ",
    services = {},
}
local group = vim.api.nvim_create_augroup(
    "TypstPreviewStateMachineSpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "TypstPreviewStopped",
    callback = function()
        local current = preview_service.get(event_project) or {}
        stopped_event_saw_inactive = current.active == false
        stopped_event_saw_result = current.last_result
            and current.last_result.reason == "event_order"
    end,
})
preview_service.set(event_project, {
    active = true,
    status = "active",
    active_backend = "callback",
    last_backend = "callback",
})
state.to_inactive(event_project, "callback", nil, nil, {
    ok = true,
    stopped = true,
    reason = "event_order",
})
pcall(vim.api.nvim_del_augroup_by_id, group)
assert(
    stopped_event_saw_inactive,
    "TypstPreviewStopped event should observe inactive preview state"
)
assert(
    stopped_event_saw_result,
    "TypstPreviewStopped event should observe final stop result"
)

local retained = state.retain_superseded_open(
    project,
    { pending = true },
    { ok = false, reason = "restart" },
    "restart",
    function(result)
        return { reason = result.reason }
    end
)
assert(retained, "retain_superseded_open should return retained entry")
assert(
    retained.pending == true,
    "retain_superseded_open should mark retained entry pending"
)
state.settle_retained_open(
    project,
    retained.id,
    { ok = true, opened = true },
    function(result)
        return { opened = result.opened }
    end
)
preview = preview_service.get(project)
assert(
    preview.retained_open_handles[1].pending == false,
    "settle_retained_open should clear pending retained state"
)
assert(
    preview.retained_open_handles[1].result.opened == true,
    "settle_retained_open should compact final result"
)

local status = state.status(project, { raw = true })
assert(status.ok == true, "status should return ok status")
assert(
    status.status == "stopping_failed",
    "status should preserve explicit preview status"
)
assert(
    status.retained_open_count == 1,
    "status should report retained open handles"
)
