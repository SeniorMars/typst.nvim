local compiler = require("typst.compiler")
local config = require("typst.config")
local consumers = require("typst.compiler.consumers")
local fragments = require("typst.compiler.fragments")
local provider_adapter = require("typst.integrations.provider_adapter")
local compiler_service = require("typst.project.services.compiler")
local log = require("typst.core.log")
local project_registry = require("typst.project")
local project_store = require("typst.project.store")
local reports = require("typst.ui.reports")
local util = require("typst.core.util")

local M = {}

local notify_user = require("typst.core.notify").user

local function is_active_handle(value)
    return provider_adapter.is_active_handle(value, {
        return_mode = "handle",
    })
end

local function compile_output(state)
    local output = (compiler_service.get(state) or {}).output
    if type(output) == "string" and output ~= "" then
        return output
    end
    return nil
end

local function compiler_provider_label(state)
    local service = compiler_service.get(state) or {}
    if
        type(service.provider_label) == "string"
        and service.provider_label ~= ""
    then
        return service.provider_label
    end
    local binding = state and state.compiler_provider or nil
    if type(binding) == "table" and type(binding.label) == "string" then
        return binding.label
    end
    return "compiler"
end

local function warn_low_confidence_main(state, action, notify)
    local project_config = (config.unsafe_get().project or {})
    if project_config.warn_on_low_confidence_main == false then
        return
    end
    if
        not state
        or state.main_confidence ~= "low"
        or state._typst_low_confidence_main_warned
    then
        return
    end

    local confidence_source = state.main_confidence_source or state.main_source
    if confidence_source ~= "root heuristic main.typ" then
        return
    end

    state._typst_low_confidence_main_warned = true
    local message = (
        "typst.nvim guessed the Typst main for %s from %s; "
        .. "use :TypstSetMain, vim.b.typst_main, or .typstmain if this is wrong"
    ):format(action, confidence_source)
    log.add("warn", "low-confidence Typst main", {
        action = action,
        root = state.root,
        main = state.main,
        main_source = state.main_source,
        main_confidence = state.main_confidence,
        main_confidence_source = confidence_source,
    })
    notify_user(notify, message, vim.log.levels.WARN)
end

--- Run one Typst compile for a project.
---@param state TypstProject Project state whose main file should be compiled.
---@param opts? table Compile options, including profile and output-opening controls.
---@param callback? fun(result:TypstCompilerResult, state:TypstProject) Callback invoked for non-stale terminal results.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return any handle Provider/process handle returned by the active compiler backend.
function M.compile(state, opts, callback, notify)
    opts = opts or {}
    warn_low_confidence_main(state, "compile", notify)
    local run_config = config.for_run(opts.profile, {
        open = opts.open,
        typst_open = opts.typst_open,
    })
    local handle = compiler.compile(state, function(result)
        if result.stale then
            return
        end

        if result.stopped then
            if callback then
                callback(result, state)
            end
            return
        end

        if result.code == 0 then
            local output = compile_output(state)
            if output then
                notify_user(
                    notify,
                    ("Compiled %s"):format(util.relpath(output, state.root))
                )
            else
                local provider = compiler_provider_label(state)
                log.add("warn", "compiler succeeded without output path", {
                    main = state and state.main or nil,
                    provider = provider,
                })
                notify_user(
                    notify,
                    ("Typst compile succeeded; provider %s did not report an output path"):format(
                        provider
                    ),
                    vim.log.levels.WARN
                )
            end
            if run_config.compile.open == true and not output then
                notify_user(
                    notify,
                    "Cannot open compile output because the compiler provider did not report one",
                    vim.log.levels.WARN
                )
            end
            consumers.after_compile(state, result, {
                open = output ~= nil and run_config.compile.open == true,
                profile = run_config.compile.profile,
            }, notify)
        else
            notify_user(
                notify,
                "Typst compile failed; use :TypstLog for details",
                vim.log.levels.ERROR
            )
        end

        if callback then
            callback(result, state)
        end
    end, run_config)
    if is_active_handle(handle) then
        notify_user(
            notify,
            ("Compiling %s%s"):format(
                util.relpath(state.main, state.root),
                run_config.compile.profile
                        and (" [" .. run_config.compile.profile .. "]")
                    or ""
            )
        )
    end
    return handle
end

--- Compile a selected Typst fragment through the fragment workflow.
---@param state TypstProject Parent project state that supplies config and root context.
---@param opts? table Fragment compile options, including range and template data.
---@param callback? fun(result:table, state:table) Callback invoked with the fragment result.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return any result Fragment compile result or pending operation handle.
function M.compile_selected(state, opts, callback, notify)
    opts = opts or {}
    return fragments.compile_selected(state, opts, callback, notify)
end

--- Return or open the latest compiler output report for a project.
---@param state TypstProject Project state whose compiler service owns the output.
---@param opts? table Report controls; `open=false` returns lines without opening a buffer.
---@return integer|nil bufnr Scratch report buffer when opened.
---@return string[] lines Compiler output lines.
function M.compile_output(state, opts)
    opts = opts or {}
    local lines = reports.compiler_output_lines(state)

    if opts.open == false then
        return nil, lines
    end

    local buf = reports.open_scratch_buffer(
        "typst.nvim compiler output",
        "typstoutput",
        lines
    )
    return buf, lines
end

--- Start or restart the Typst watch backend for a project.
---@param state TypstProject Project state whose watcher should be owned by compiler services.
---@param opts? table Watch options, including profile and output-opening controls.
---@param callback? fun(result:TypstCompilerResult, state:TypstProject) Callback invoked for non-stale watch results.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return any handle Provider/process handle returned by the active compiler backend.
function M.watch(state, opts, callback, notify)
    opts = opts or {}
    warn_low_confidence_main(state, "watch", notify)
    local run_config = config.for_run(opts.profile, {
        open = opts.open,
        typst_open = opts.typst_open,
    })
    local viewer_opened = false

    local handle = compiler.start(state, function(result)
        if result.stale then
            return
        end

        if not result.stopped and result.code ~= 0 then
            notify_user(
                notify,
                "Typst watch failed; use :TypstLog for details",
                vim.log.levels.ERROR
            )
        end

        if not result.stopped then
            local open = run_config.compile.open == true
                and not viewer_opened
                and result.code == 0
            local consumer_result = consumers.after_watch_cycle(state, result, {
                open = open,
                profile = run_config.compile.profile,
            }, notify)
            if
                open
                and consumer_result
                and consumer_result.opened ~= false
                and not (
                    type(consumer_result.opened) == "table"
                    and consumer_result.opened.ok == false
                )
            then
                viewer_opened = true
            end
        end

        if callback then
            callback(result, state)
        end
    end, run_config)
    if is_active_handle(handle) then
        notify_user(
            notify,
            ("Watching %s%s"):format(
                util.relpath(state.main, state.root),
                run_config.compile.profile
                        and (" [" .. run_config.compile.profile .. "]")
                    or ""
            )
        )
    end
    return handle
end

--- Stop the active compiler or watcher for one project.
---@param state TypstProject Project whose compiler resources should stop. On Windows, built-in process stops target the whole process tree.
---@param callback? fun(result:TypstCompilerResult, state:TypstProject) Callback invoked with stop status.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table|boolean|nil result Stop result or pending cancellation handle; `stopped=true` means no writer remains.
function M.stop(state, callback, notify)
    return compiler.stop(state, function(result)
        if result.idle then
            notify_user(
                notify,
                ("No active Typst compiler for %s"):format(
                    util.relpath(state.main, state.root)
                )
            )
        elseif result.stopped then
            notify_user(
                notify,
                ("Stopped %s"):format(util.relpath(state.main, state.root))
            )
        end

        if callback then
            callback(result, state)
        end
    end)
end

--- Force-clear unconfirmed external compiler provider state for one project.
---@param state TypstProject? Project state whose compiler state may be discarded.
---@param opts? {force?:boolean, notify?:boolean} Clear controls; force bypasses the stopping_failed guard.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return TypstCompilerResult result Force-clear status.
function M.force_clear(state, opts, notify)
    opts = opts or {}
    if not state then
        local result = {
            ok = false,
            code = 1,
            stale = false,
            stopped = false,
            reason = "no_project",
            message = "No Typst project is attached; pass a project key or run from a Typst buffer",
        }
        if opts.notify ~= false then
            notify_user(notify, result.message, vim.log.levels.ERROR)
        end
        return result
    end

    local result = compiler.force_clear(state, opts)
    if result.ok and result.discarded then
        if opts.notify ~= false then
            notify_user(
                notify,
                ("Cleared unconfirmed external compiler state for %s"):format(
                    util.relpath(state.main, state.root)
                ),
                vim.log.levels.WARN
            )
        end
    elseif result.ok and opts.notify ~= false then
        notify_user(
            notify,
            result.message or "No external compiler state was cleared"
        )
    elseif opts.notify ~= false then
        notify_user(
            notify,
            result.message or "No external compiler state was cleared",
            vim.log.levels.ERROR
        )
    end
    return result
end

--- Stop compiler resources for every tracked project.
---@param opts? table Stop options forwarded to project operation cancellation.
---@param callback? fun(result:TypstCompilerResult, state:TypstProject, summary:table) Callback invoked once per project stop result.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table summary Aggregate stop counts by project state.
function M.stop_all(opts, callback, notify)
    opts = opts or {}

    local states = vim.tbl_values(project_store.all())
    table.sort(states, function(left, right)
        return left.main < right.main
    end)
    local summary = {
        total = #states,
        active = 0,
        stopped = 0,
        idle = 0,
        failed = 0,
    }

    if #states == 0 then
        if opts.notify ~= false then
            notify_user(notify, "No Typst projects are registered")
        end
        return summary
    end

    local pending = #states
    local function finish()
        pending = pending - 1
        if pending == 0 and opts.notify ~= false then
            notify_user(
                notify,
                ("Stopped %d active Typst project%s (%d idle, %d failed)"):format(
                    summary.stopped,
                    summary.stopped == 1 and "" or "s",
                    summary.idle,
                    summary.failed
                )
            )
        end
    end

    for _, state in ipairs(states) do
        local compiler_state = compiler_service.get(state) or {}
        if compiler_state.process or compiler_state.watcher then
            summary.active = summary.active + 1
        end

        compiler.stop(state, function(result)
            if result.idle then
                summary.idle = summary.idle + 1
            elseif result.stopped then
                summary.stopped = summary.stopped + 1
            else
                summary.failed = summary.failed + 1
            end

            if callback then
                callback(result, state, summary)
            end

            finish()
        end)
    end

    return summary
end

return M
