local core_lifecycle = require("typst.core.lifecycle")
local events = require("typst.core.events")
local project = require("typst.project")

local M = {}

local function buffer_event_payload(state, bufnr, reason, resolution)
    local buffers = vim.tbl_keys(state and state.bufs or {})
    return {
        event_kind = "buffer_detach",
        bufnr = bufnr,
        buffer = resolution and resolution.buffer or nil,
        reason = reason,
        remaining_buffers = #buffers,
        project_pruned = project.pruned(state),
    }
end

function M.emit_project_pruned(state, reason)
    if project.pruned(state) then
        project.emit_pruned(state, reason)
    end
end

function M.emit_buffer_detach(previous, bufnr, reason, resolution)
    if not previous then
        return
    end
    events.emit(
        "TypstBufferDetach",
        previous,
        buffer_event_payload(previous, bufnr, reason, resolution)
    )
end

function M.emit_project_attach(state, bufnr, reason)
    if not state then
        return
    end
    local resolution = state.resolutions and state.resolutions[bufnr] or nil
    events.emit("TypstProjectAttach", state, {
        event_kind = "project_attach",
        bufnr = bufnr,
        buffer = resolution and resolution.buffer or nil,
        reason = reason,
        remaining_buffers = #vim.tbl_keys(state.bufs or {}),
    })
end

function M.emit_reassign(previous, state, bufnr, reason, previous_resolution)
    local previous_key = previous and previous.key or nil
    local state_key = state and state.key or nil
    if previous_key == state_key then
        return
    end

    if previous then
        local resolution = previous_resolution
            or (previous.resolutions and previous.resolutions[bufnr])
        M.emit_buffer_detach(
            previous,
            bufnr,
            reason or "buffer reassigned",
            resolution
        )
        M.emit_project_pruned(previous, reason or "buffer reassigned")
    end
    if state then
        M.emit_project_attach(state, bufnr, reason or "buffer attached")
    end
end

function M.stop_previous(previous, reason, message)
    core_lifecycle.stop_before_prune(previous, reason, message)
end

return M
