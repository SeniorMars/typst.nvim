local config = require("typst.config")
local log = require("typst.core.log")
local compiler_service = require("typst.project.services.compiler")
local preview_service = require("typst.project.services.preview")
local viewer_service = require("typst.project.services.viewer")

-- User-event bridge for Typst project lifecycle notifications.
--
-- Event handlers are user code, so state changes triggered from inside them are
-- deferred until the outermost emit finishes. That keeps autocmd callbacks from
-- re-entering project attach/detach logic while aliases for the same event are
-- still being delivered.
local M = {}
local emitting_depth = 0
local deferred_state_changes = {}
local draining_deferred = false
local reset_generation = 0

-- `TypstEvent*` names are the documented autocmd surface. The shorter
-- `TypstCompileStarted`-style names remain as compatibility aliases, so event
-- payload changes should be additive unless the public API version changes.
local aliases = require("typst.api.contract").event_aliases()

--- Build the payload used for Typst `User` lifecycle events.
---@param project table Project state whose service metadata should be exposed.
---@param overrides? table Event-specific payload fields.
---@return table data Payload passed to `nvim_exec_autocmds`.
function M.data(project, overrides)
    local compiler = compiler_service.get(project) or {}
    local preview = preview_service.get(project) or {}
    local viewer = viewer_service.get(project) or {}
    return vim.tbl_extend("force", {
        key = project.key,
        root = project.root,
        main = project.main,
        output = compiler.output,
        status = compiler.status,
        provider = config.provider_label(),
        profile = compiler.last_profile,
        cwd = compiler.last_cwd or project.root,
        command = compiler.last_command and vim.deepcopy(compiler.last_command)
            or nil,
        viewer_backend = viewer.backend,
        viewer_command = viewer.command and vim.deepcopy(viewer.command) or nil,
        viewer_cwd = viewer.cwd,
        preview_backend = preview.last_backend,
        preview_command = preview.last_command and vim.deepcopy(
            preview.last_command
        ) or nil,
        preview_cwd = preview.last_cwd,
        preview_mode = preview.last_mode,
        preview_active = preview.active == true,
    }, overrides or {})
end

local function emit_one(pattern, data)
    -- Each User event gets its own payload snapshot so one autocmd cannot mutate
    -- the data seen by later aliases in the same batch.
    local snapshot = vim.deepcopy(data or {})
    local ok, err = xpcall(function()
        vim.api.nvim_exec_autocmds("User", {
            pattern = pattern,
            data = snapshot,
        })
    end, debug.traceback)
    if not ok then
        log.add("error", "Typst user event failed", {
            pattern = pattern,
            error = err,
        })
    end
end

local function drain_deferred()
    -- Deferred callbacks may emit more Typst events. Drain in batches and let
    -- nested emits finish before running the next set of state mutations.
    if draining_deferred or emitting_depth > 0 then
        return
    end

    draining_deferred = true
    while #deferred_state_changes > 0 do
        local pending = deferred_state_changes
        deferred_state_changes = {}
        for _, item in ipairs(pending) do
            local ok, err = xpcall(item.fn, debug.traceback)
            if not ok then
                log.add("error", "deferred Typst state change failed", {
                    label = item.label,
                    error = err,
                })
            end
        end
    end
    draining_deferred = false
end

local function emit_batch(items)
    local generation = reset_generation
    emitting_depth = emitting_depth + 1
    for _, item in ipairs(items) do
        emit_one(item.pattern, item.data)
        if reset_generation ~= generation then
            return
        end
    end

    emitting_depth = emitting_depth - 1
    if emitting_depth == 0 then
        drain_deferred()
    end
end

--- Emit a project-scoped Typst user event and its compatibility aliases.
---@param pattern string Primary `User` autocmd pattern to emit.
---@param project table Project state used to build the event payload.
---@param overrides? table Event-specific payload fields.
function M.emit(pattern, project, overrides)
    local data = M.data(project, overrides)
    local items = {
        {
            pattern = pattern,
            data = data,
        },
    }
    for _, alias in ipairs(aliases[pattern] or {}) do
        items[#items + 1] = {
            pattern = alias,
            data = data,
        }
    end
    emit_batch(items)
end

--- Emit a plugin-scoped Typst user event without project state.
---@param pattern string `User` autocmd pattern to emit.
---@param overrides? table Event-specific payload fields.
function M.emit_global(pattern, overrides)
    emit_batch({
        {
            pattern = pattern,
            data = vim.tbl_extend("force", {
                provider = config.provider_label(),
            }, overrides or {}),
        },
    })
end

--- Report whether typst.nvim is currently emitting a user event.
---@return boolean active True when currently inside an event emission.
function M.in_user_event()
    return emitting_depth > 0
end

--- Queue a lifecycle mutation until active Typst user events finish.
---@param label? string Human-readable label used in error logs.
---@param fn fun() Mutation to run after the outermost event emission.
---@return boolean deferred True when the mutation was queued instead of run immediately.
function M.defer_state_change(label, fn)
    -- Lifecycle code calls this only while publishing a User event; outside that
    -- path the caller should perform the mutation immediately.
    if type(fn) ~= "function" or emitting_depth == 0 then
        return false
    end

    deferred_state_changes[#deferred_state_changes + 1] = {
        label = label or "state-change",
        fn = fn,
    }
    return true
end

--- Clear active event/deferred lifecycle state during runtime reset.
function M.reset()
    reset_generation = reset_generation + 1
    emitting_depth = 0
    deferred_state_changes = {}
    draining_deferred = false
end

M._reset_for_tests = M.reset

return M
