local config = require("typst.config")
local cursor_position = require("typst.completion.position")
local log = require("typst.core.log")
local open_helper = require("typst.core.open")
local operation = require("typst.core.operation")
local providers = require("typst.integrations.providers")
local compiler_service = require("typst.project.services.compiler")
local viewer_service = require("typst.project.services.viewer")
local util = require("typst.core.util")

local M = {}

local function list_is_empty(value)
    return type(value) ~= "table" or #value == 0
end

--- Merge viewer config with the selected viewer provider defaults.
---@return table viewer Effective viewer configuration.
function M.effective_viewer()
    local viewer = vim.deepcopy(config.unsafe_get().viewer)
    local provider_name = viewer.provider or "generic"
    local provider = providers.get("viewer", provider_name)
        or (viewer.providers or {})[provider_name]
        or {}
    if type(provider) == "function" then
        provider = { open = provider }
    end
    viewer.provider = provider_name
    viewer.capabilities = vim.tbl_extend(
        "force",
        provider.capabilities or {},
        viewer.capabilities or {}
    )

    -- User config wins over provider defaults field-by-field. This lets a
    -- provider supply forward/inverse helpers without replacing an explicitly
    -- configured opener or argument list.
    if viewer.open == nil then
        viewer.open = provider.open
    end
    if viewer.reload == nil then
        viewer.reload = provider.reload
    end
    if list_is_empty(viewer.args) and provider.args ~= nil then
        viewer.args = vim.deepcopy(provider.args)
    end
    if viewer.forward == nil then
        viewer.forward = provider.forward
    end
    if list_is_empty(viewer.forward_args) and provider.forward_args ~= nil then
        viewer.forward_args = vim.deepcopy(provider.forward_args)
    end
    if viewer.inverse == nil then
        viewer.inverse = provider.inverse
    end
    if list_is_empty(viewer.inverse_args) and provider.inverse_args ~= nil then
        viewer.inverse_args = vim.deepcopy(provider.inverse_args)
    end

    return viewer
end

--- Build a user/report-facing backend name for a viewer action.
---@param viewer table Effective viewer configuration.
---@param suffix? string Action/backend suffix.
---@return string name Backend name.
function M.backend_name(viewer, suffix)
    if
        viewer.provider
        and viewer.provider ~= "generic"
        and viewer.provider ~= "custom"
    then
        return suffix and (viewer.provider .. "-" .. suffix) or viewer.provider
    end

    return suffix or "executable"
end

--- Clear the last successful viewer backend recorded for a project.
---@param project table Project state whose viewer service is mutated.
function M.clear_last_viewer(project)
    viewer_service.set(project, {
        clear = { "provider", "backend", "command", "cwd" },
    })
end

--- Record the viewer backend that successfully handled a project action.
---@param project table Project state whose viewer service is mutated.
---@param viewer table Effective viewer configuration.
---@param backend string Backend label to store.
---@param command? string[] Command used by executable backends.
---@param cwd? string Working directory used by executable backends.
function M.record_last_viewer(project, viewer, backend, command, cwd)
    viewer_service.set(project, {
        clear = { "provider", "backend", "command", "cwd" },
        provider = viewer.provider,
        backend = backend,
        command = command,
        cwd = cwd,
    })
end

--- Build a normalized failure payload for viewer callback exceptions.
---@param viewer table Effective viewer configuration.
---@param action string Viewer action name.
---@param err any Callback error object.
---@return table result Failure payload.
function M.callback_error(viewer, action, err)
    return {
        ok = false,
        reason = "callback_error",
        message = ("Typst viewer %s callback failed"):format(action),
        provider = viewer.provider,
        error = err,
        capabilities = vim.deepcopy(viewer.capabilities or {}),
    }
end

local function apply_placeholders(value, context)
    local replaced = value
    replaced = replaced:gsub("{output}", context.output)
    replaced = replaced:gsub("{main}", context.main)
    replaced = replaced:gsub("{root}", context.root)
    replaced = replaced:gsub("{line}", tostring(context.line))
    replaced = replaced:gsub("{column}", tostring(context.column))
    replaced = replaced:gsub("{source}", context.source or context.main)
    replaced = replaced:gsub("{file}", context.source or context.main)
    replaced = replaced:gsub("{path}", context.source or context.main)
    return replaced
end

--- Build a viewer command by applying path and source-sync placeholders.
---@param command_prefix string|string[] Viewer executable command prefix.
---@param args? string[] Viewer argument templates.
---@param context table Placeholder context with output/root/source coordinates.
---@param opts? table Command options; `append_output=false` suppresses implicit output.
---@return string[] command Executable plus resolved arguments.
function M.viewer_command(command_prefix, args, context, opts)
    opts = opts or {}
    local command = util.command_prefix(command_prefix)
    local has_output = false

    for _, arg in ipairs(args or {}) do
        if arg:find("{output}", 1, true) then
            has_output = true
        end
        command[#command + 1] = apply_placeholders(arg, context)
    end

    if opts.append_output ~= false and not has_output then
        -- Viewer integrations usually append the output path implicitly. If a
        -- user writes an explicit {output} placeholder, honor their argument
        -- order.
        command[#command + 1] = context.output
    end

    return command
end

--- Open a PDF through a configured executable viewer.
---@param project table Project state used for cwd and viewer recording.
---@param path string Output path to open.
---@param viewer table Effective viewer configuration.
---@return boolean opened True when an executable viewer was configured and started.
function M.executable_open(project, path, viewer)
    if type(viewer.open) == "string" or type(viewer.open) == "table" then
        local opener = util.command_executable(viewer.open)
        if vim.fn.executable(opener) ~= 1 then
            error(
                ("typst.nvim: viewer executable not found in PATH: %s"):format(
                    opener
                )
            )
        end

        local command = M.viewer_command(viewer.open, viewer.args, {
            output = path,
            main = project.main,
            root = project.root,
            line = 1,
            column = 1,
        })

        local viewer_operation = operation.run("viewer-open", command, {
            cwd = project.root,
            text = true,
        }, {
            on_finish = function(result)
                if result.code ~= 0 then
                    log.add("error", "viewer command failed", {
                        command = command,
                        cwd = project.root,
                        code = result.code,
                        stderr = result.stderr,
                    })
                end
            end,
        })

        if
            viewer_operation.handle
            and viewer_operation.handle._typst_spawn_error
        then
            error(
                ("typst.nvim: failed to start viewer %s: %s"):format(
                    opener,
                    viewer_operation.handle._typst_spawn_error.error
                )
            )
        end

        M.record_last_viewer(
            project,
            viewer,
            M.backend_name(viewer),
            command,
            project.root
        )
        return true
    end

    return false
end

local function current_position(opts)
    opts = opts or {}
    if opts.line or opts.column then
        return {
            line = opts.line or vim.fn.line("."),
            column = opts.column or vim.fn.col("."),
        }
    end

    local resolved = cursor_position.resolve(opts)
    if resolved then
        return {
            line = resolved.row + 1,
            column = resolved.col + 1,
        }
    end

    if opts.bufnr ~= nil or opts.winid ~= nil or opts.pos ~= nil then
        return nil
    end

    return {
        line = vim.fn.line("."),
        column = vim.fn.col("."),
    }
end

--- Build placeholder context for viewer forward search.
---@param project table Project state that supplies root/main paths.
---@param path string Output path being searched.
---@param opts? table Forward-search options.
---@return table context Viewer placeholder context.
function M.forward_context(project, path, opts)
    local position = current_position(opts)
    if not position then
        return nil
    end
    return {
        output = path,
        main = project.main,
        root = project.root,
        line = position.line,
        column = position.column,
    }
end

--- Resolve viewer inverse-search options into a source location.
---@param project table Project state used to resolve root-relative source paths.
---@param opts? table Inverse-search options.
---@return table location Source location with path, line, column, and output.
function M.source_location(project, opts)
    opts = opts or {}
    local path = opts.path or opts.file or opts.source or project.main
    local output = (compiler_service.get(project) or {}).output
    return {
        path = util.resolve_path(path, project.root),
        line = math.max(tonumber(opts.line) or 1, 1),
        column = math.max(tonumber(opts.column) or 1, 1),
        output = output,
    }
end

--- Build placeholder context for viewer inverse search.
---@param project table Project state that supplies root/main paths.
---@param location table Source location from `source_location`.
---@return table context Viewer placeholder context.
function M.inverse_context(project, location)
    local output = (compiler_service.get(project) or {}).output
    return {
        output = location.output or output or "",
        source = location.path,
        main = project.main,
        root = project.root,
        line = location.line,
        column = location.column,
    }
end

--- Jump the destination Neovim window to a viewer-reported source location.
---@param location table Source location with path, line, and column.
---@param opts? table Jump options; `open_winid` selects the destination window.
---@return table result Jump result or normalized failure payload.
function M.jump_to_source(location, opts)
    if not location.path or location.path == "" then
        return {
            ok = false,
            reason = "missing_source",
            message = "No source path was provided for Typst viewer inverse search",
        }
    end

    local opened, err = open_helper.file(location.path, opts)
    if not opened then
        return {
            ok = false,
            reason = "open_failed",
            message = ("Failed to open viewer source: %s"):format(
                err or "unknown error"
            ),
            path = location.path,
        }
    end

    local line_count = math.max(vim.api.nvim_buf_line_count(opened.bufnr), 1)
    local line = math.min(math.max(location.line, 1), line_count)
    local col = math.max(location.column - 1, 0)
    vim.api.nvim_win_set_cursor(opened.winid, { line, col })

    return {
        ok = true,
        path = location.path,
        bufnr = opened.bufnr,
        winid = opened.winid,
        line = line,
        column = col + 1,
    }
end

return M
