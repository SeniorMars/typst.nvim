local events = require("typst.core.events")
local generic_helpers = require("typst.viewer.generic_helpers")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local provider_adapter = require("typst.integrations.provider_adapter")
local compiler_service = require("typst.project.services.compiler")
local viewer_service = require("typst.project.services.viewer")
local util = require("typst.core.util")

local M = {}

local effective_viewer = generic_helpers.effective_viewer
local backend_name = generic_helpers.backend_name
local record_last_viewer = generic_helpers.record_last_viewer
local callback_error = generic_helpers.callback_error
local viewer_command = generic_helpers.viewer_command
local forward_context = generic_helpers.forward_context
local source_location = generic_helpers.source_location
local inverse_context = generic_helpers.inverse_context
local jump_to_source = generic_helpers.jump_to_source

local function failed_result(result)
    return type(result) == "table" and result.ok == false
end

local function has_sync_capability(viewer, action)
    local capabilities = viewer.capabilities or {}
    return capabilities[action] == true or capabilities.source_maps == true
end

local function unsupported_result(viewer, action, message, extra)
    local result = {
        ok = false,
        reason = "unsupported",
        message = message,
        provider = viewer.provider,
        capabilities = vim.deepcopy(viewer.capabilities or {}),
    }

    if type(extra) == "table" then
        result = vim.tbl_extend("force", result, extra)
    end

    log.add("warn", ("viewer %s unsupported"):format(action), {
        provider = viewer.provider,
        capabilities = viewer.capabilities,
        detail = result.detail,
    })
    return result
end

--- Run forward search through the effective viewer backend.
---@param project table Project state whose output and source paths define the context.
---@param opts? table Forward-search options.
---@return table|boolean|nil result Viewer callback/operation result or failure payload.
function M.forward(project, opts)
    opts = opts or {}
    local path = (compiler_service.get(project) or {}).output
    if not path or vim.fn.filereadable(path) ~= 1 then
        error(("typst.nvim: output does not exist: %s"):format(path or "<nil>"))
    end

    local viewer = effective_viewer()
    local forward = viewer.forward
    if forward == nil then
        return unsupported_result(
            viewer,
            "forward",
            "No Typst viewer forward-search backend is configured",
            {
                main = project.main,
                output = path,
            }
        )
    end

    if
        type(forward) ~= "function"
        and not has_sync_capability(viewer, "forward")
    then
        return unsupported_result(
            viewer,
            "forward",
            "Typst viewer forward-search command is configured but source-sync capability is disabled",
            {
                detail = "capability_required",
                main = project.main,
                output = path,
            }
        )
    end

    local context = forward_context(project, path, opts)
    if not context then
        return {
            ok = false,
            reason = "position_required",
            message = "Viewer forward search requires a source position for the target buffer",
            provider = viewer.provider,
            capabilities = vim.deepcopy(viewer.capabilities or {}),
        }
    end

    local result
    if type(forward) == "function" then
        result = provider_adapter.invoke(
            {
                name = viewer.provider,
                forward = forward,
            },
            "forward",
            project,
            opts,
            {
                kind = "viewer-forward",
                provider_name = viewer.provider,
                async = false,
                allow_nil_result = true,
                args = {
                    path,
                    project,
                    {
                        line = context.line,
                        column = context.column,
                    },
                    opts,
                },
                callback_position = 5,
                normalize = function(raw)
                    return raw == nil and true or raw
                end,
            }
        )
        if failed_result(result) then
            result = callback_error(
                viewer,
                "forward",
                result.error or result.message
            )
            log.add("warn", "viewer forward callback failed", {
                provider = viewer.provider,
                main = project.main,
                output = path,
                error = result.error or result.message,
            })
        end
        if result ~= false and not failed_result(result) then
            record_last_viewer(
                project,
                viewer,
                backend_name(viewer, "forward-callback"),
                nil,
                nil
            )
        end
    else
        local opener = util.command_executable(forward)
        if vim.fn.executable(opener) ~= 1 then
            error(
                ("typst.nvim: viewer forward executable not found in PATH: %s"):format(
                    opener
                )
            )
        end

        local command = viewer_command(forward, viewer.forward_args, context)
        local viewer_operation = operation.run("viewer-forward", command, {
            cwd = project.root,
            text = true,
        }, {
            on_finish = function(system_result)
                if system_result.code ~= 0 then
                    log.add("error", "viewer forward command failed", {
                        command = command,
                        cwd = project.root,
                        code = system_result.code,
                        stderr = system_result.stderr,
                    })
                end
            end,
        })
        if
            viewer_operation.handle
            and viewer_operation.handle._typst_spawn_error
        then
            error(
                ("typst.nvim: failed to start viewer forward %s: %s"):format(
                    opener,
                    viewer_operation.handle._typst_spawn_error.error
                )
            )
        end
        record_last_viewer(
            project,
            viewer,
            backend_name(viewer, "forward-executable"),
            command,
            project.root
        )
        result = viewer_operation
    end

    if result ~= false and not failed_result(result) then
        local viewer_state = viewer_service.get(project) or {}
        log.add("info", "view forwarded", {
            provider = viewer.provider,
            output = path,
            line = context.line,
            column = context.column,
            backend = viewer_state.backend,
        })
        events.emit("TypstViewForwarded", project, {
            viewer_provider = viewer.provider,
            output = path,
            line = context.line,
            column = context.column,
            viewer_backend = viewer_state.backend,
        })
    end

    return result
end

--- Run inverse search through the effective viewer backend.
---@param project table Project state whose source paths define the context.
---@param opts? table Inverse-search options.
---@return table|boolean|nil result Viewer callback/operation result or failure payload.
function M.inverse(project, opts)
    opts = opts or {}
    local viewer = effective_viewer()
    local inverse = viewer.inverse
    local capabilities = viewer.capabilities or {}
    local can_default_jump = capabilities.inverse == true
        or capabilities.source_maps == true
    if inverse == nil and not can_default_jump then
        return unsupported_result(
            viewer,
            "inverse",
            "No Typst viewer inverse-search backend is configured",
            {
                main = project.main,
                output = (compiler_service.get(project) or {}).output,
            }
        )
    end

    if
        inverse ~= nil
        and type(inverse) ~= "function"
        and not has_sync_capability(viewer, "inverse")
    then
        return unsupported_result(
            viewer,
            "inverse",
            "Typst viewer inverse-search command is configured but source-sync capability is disabled",
            {
                detail = "capability_required",
                main = project.main,
                output = (compiler_service.get(project) or {}).output,
            }
        )
    end

    -- Some viewers can call back into Neovim with source-map coordinates but do
    -- not need an executable inverse command. Treat source_maps as enough to
    -- perform the editor-side jump.
    local location = source_location(project, opts)
    local result
    if type(inverse) == "function" then
        result = provider_adapter.invoke(
            {
                name = viewer.provider,
                inverse = inverse,
            },
            "inverse",
            project,
            opts,
            {
                kind = "viewer-inverse",
                provider_name = viewer.provider,
                async = false,
                allow_nil_result = true,
                args = {
                    project,
                    {
                        path = location.path,
                        line = location.line,
                        column = location.column,
                        output = location.output,
                    },
                    opts,
                },
                callback_position = 4,
                normalize = function(raw)
                    return raw == nil and true or raw
                end,
            }
        )
        if failed_result(result) then
            result = callback_error(
                viewer,
                "inverse",
                result.error or result.message
            )
            log.add("warn", "viewer inverse callback failed", {
                provider = viewer.provider,
                main = project.main,
                output = location.output,
                source = location.path,
                error = result.error or result.message,
            })
        end
        if result ~= false and not failed_result(result) then
            record_last_viewer(
                project,
                viewer,
                backend_name(viewer, "inverse-callback"),
                nil,
                nil
            )
        end
    elseif inverse ~= nil then
        local opener = util.command_executable(inverse)
        if vim.fn.executable(opener) ~= 1 then
            error(
                ("typst.nvim: viewer inverse executable not found in PATH: %s"):format(
                    opener
                )
            )
        end

        local command = viewer_command(
            inverse,
            viewer.inverse_args,
            inverse_context(project, location),
            {
                append_output = false,
            }
        )
        local viewer_operation = operation.run("viewer-inverse", command, {
            cwd = project.root,
            text = true,
        }, {
            on_finish = function(system_result)
                if system_result.code ~= 0 then
                    log.add("error", "viewer inverse command failed", {
                        command = command,
                        cwd = project.root,
                        code = system_result.code,
                        stderr = system_result.stderr,
                    })
                end
            end,
        })
        if
            viewer_operation.handle
            and viewer_operation.handle._typst_spawn_error
        then
            error(
                ("typst.nvim: failed to start viewer inverse %s: %s"):format(
                    opener,
                    viewer_operation.handle._typst_spawn_error.error
                )
            )
        end
        record_last_viewer(
            project,
            viewer,
            backend_name(viewer, "inverse-executable"),
            command,
            project.root
        )
        result = viewer_operation
    else
        result = jump_to_source(location, opts)
        if result.ok then
            record_last_viewer(
                project,
                viewer,
                backend_name(viewer, "inverse-source-map"),
                nil,
                nil
            )
        end
    end

    if result ~= false and not failed_result(result) then
        local viewer_state = viewer_service.get(project) or {}
        log.add("info", "view inverse search", {
            provider = viewer.provider,
            source = location.path,
            output = location.output,
            line = location.line,
            column = location.column,
            backend = viewer_state.backend,
        })
        events.emit("TypstViewInverse", project, {
            viewer_provider = viewer.provider,
            output = location.output,
            path = location.path,
            line = location.line,
            column = location.column,
            viewer_backend = viewer_state.backend,
        })
    end

    return result
end

--- Return source-sync capabilities for the effective viewer backend.
---@return table capabilities Capability snapshot for open/forward/inverse behavior.
function M.capabilities()
    local viewer = effective_viewer()
    local capabilities = viewer.capabilities or {}
    return {
        provider = viewer.provider,
        open = viewer.open ~= nil
            or viewer.provider == "generic"
            or viewer.provider == "custom",
        forward = viewer.forward ~= nil
            and (
                type(viewer.forward) == "function"
                or has_sync_capability(viewer, "forward")
            ),
        inverse = viewer.inverse ~= nil
                and (type(viewer.inverse) == "function" or has_sync_capability(
                    viewer,
                    "inverse"
                ))
            or capabilities.inverse == true
            or capabilities.source_maps == true,
        source_maps = capabilities.source_maps == true,
        configured_forward = viewer.forward ~= nil,
        configured_inverse = viewer.inverse ~= nil,
        capabilities = vim.deepcopy(capabilities),
    }
end

return M
