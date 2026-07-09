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

local function clear_event_state()
    emitting_depth = 0
    deferred_state_changes = {}
    draining_deferred = false
end

local function cancel_deferred_items(items, reason)
    for _, item in ipairs(items or {}) do
        if type(item.on_cancel) == "function" then
            local ok, err = xpcall(function()
                item.on_cancel(reason or "reset")
            end, debug.traceback)
            if not ok then
                log.add("error", "deferred Typst state cancellation failed", {
                    label = item.label,
                    error = err,
                })
            end
        end
    end
end

-- `TypstEvent*` names are the documented autocmd surface. A few shorter
-- pre-1.0 names and deprecated duplicate `TypstEvent*` aliases remain until an
-- explicit API/deprecation decision removes them.
local aliases = require("typst.api.contract").event_aliases()

local function provider_label(project, compiler)
    -- Provider identity belongs to the active compiler binding, not the current
    -- global config. setup() may reconfigure providers while an older
    -- compile/watch is still stopping or emitting terminal events, so current
    -- config is only a fallback when no project-local owner is recorded.
    if type(compiler.provider_label) == "string" then
        return compiler.provider_label
    end
    if
        type(project) == "table"
        and type(project.compiler_provider) == "table"
        and type(project.compiler_provider.label) == "string"
    then
        return project.compiler_provider.label
    end
    return config.provider_label()
end

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
        provider = provider_label(project, compiler),
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

    local generation = reset_generation
    draining_deferred = true
    while #deferred_state_changes > 0 and reset_generation == generation do
        local pending = deferred_state_changes
        deferred_state_changes = {}
        for index, item in ipairs(pending) do
            if reset_generation ~= generation then
                local remaining = {}
                for remaining_index = index, #pending do
                    remaining[#remaining + 1] = pending[remaining_index]
                end
                cancel_deferred_items(remaining, "reset")
                break
            end
            local ok, err = xpcall(item.fn, debug.traceback)
            if not ok then
                log.add("error", "deferred Typst state change failed", {
                    label = item.label,
                    error = err,
                })
            end
        end
    end
    if reset_generation ~= generation then
        clear_event_state()
    else
        draining_deferred = false
    end
end

local function emit_batch(items)
    local generation = reset_generation
    emitting_depth = emitting_depth + 1

    local ok, err = xpcall(function()
        for _, item in ipairs(items) do
            emit_one(item.pattern, item.data)
            if reset_generation ~= generation then
                break
            end
        end
    end, debug.traceback)
    if reset_generation ~= generation then
        -- Keep the finalizer explicit so future generation changes cannot
        -- strand event emission depth.
        clear_event_state()
    else
        emitting_depth = math.max(0, emitting_depth - 1)
        if emitting_depth == 0 then
            drain_deferred()
        end
    end

    if not ok then
        log.add("error", "Typst event batch failed", {
            error = err,
        })
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
---@param opts? {on_cancel?:fun(reason:string)} Cancellation hook called when reset drops the queued mutation.
---@return boolean deferred True when the mutation was queued for later.
function M.defer_state_change(label, fn, opts)
    -- Lifecycle code calls this only while publishing a User event; outside that
    -- path the caller should perform the mutation immediately.
    if type(fn) ~= "function" or emitting_depth == 0 then
        return false
    end

    opts = opts or {}
    deferred_state_changes[#deferred_state_changes + 1] = {
        label = label or "state-change",
        fn = fn,
        on_cancel = opts.on_cancel,
    }
    return true
end

--- Cancel queued deferred lifecycle mutations.
---@param opts? {reason?:string} Cancellation controls.
---@return table result Cancellation summary.
function M.cancel_deferred(opts)
    opts = opts or {}
    local pending = deferred_state_changes
    deferred_state_changes = {}
    cancel_deferred_items(pending, opts.reason or "reset")
    return {
        ok = true,
        cancelled = #pending,
    }
end

--- Return a summary-safe deferred event queue snapshot.
---@return table snapshot Deferred queue state.
function M.deferred_snapshot()
    return {
        count = #deferred_state_changes,
        emitting_depth = emitting_depth,
        draining = draining_deferred,
        reset_generation = reset_generation,
    }
end

--- Clear active event/deferred lifecycle state during runtime reset.
function M.reset()
    reset_generation = reset_generation + 1
    M.cancel_deferred({ reason = "reset" })
    clear_event_state()
end

M._reset_for_tests = M.reset
M._state_for_tests = function()
    return {
        emitting_depth = emitting_depth,
        deferred_count = #deferred_state_changes,
        draining_deferred = draining_deferred,
        reset_generation = reset_generation,
    }
end

return M
