local compiler_service = require("typst.project.services.compiler")
local config = require("typst.config")
local log = require("typst.core.log")
local pending_handle = require("typst.core.pending")
local operations = require("typst.project.services.operations")
local preview_cache = require("typst.preview.cache")
local session = require("typst.preview.native.session")
local util = require("typst.core.util")
local xdg = require("typst.core.xdg")

local M = {}

local function noop() end

local function provider_label(provider)
    if type(provider) == "string" then
        return provider
    end
    if type(provider) == "function" then
        return "callback"
    end
    if type(provider) == "table" then
        return provider.name or "table"
    end
    return nil
end

local function output_path(project)
    local path = (compiler_service.get(project) or {}).output
    if not path or vim.fn.filereadable(path) ~= 1 then
        error(("typst.nvim: output does not exist: %s"):format(path or "<nil>"))
    end
    return path
end

local function copy_export(value)
    return type(value) == "table" and vim.deepcopy(value) or {}
end

local function non_empty_list(value)
    return type(value) == "table" and #value > 0
end

local function inherited_export(preview, target)
    local base = copy_export(preview.export)
    if target ~= "browser" then
        base.mode = base.mode or "compile"
        return base
    end

    local browser = copy_export(preview.browser and preview.browser.export)
    if browser.mode == nil or browser.mode == "inherit" then
        browser.mode = nil
        local inherited = vim.tbl_extend("force", base, browser)
        inherited.mode = base.mode or "compile"
        if not non_empty_list(browser.extra_args) then
            inherited.extra_args = vim.deepcopy(base.extra_args or {})
        end
        return inherited
    end

    browser.extra_args = vim.deepcopy(browser.extra_args or {})
    return browser
end

local function apply_overrides(export, opts)
    opts = opts or {}
    local override = opts.preview_export or opts.export or opts
    if type(override) ~= "table" then
        return export
    end

    if override.export_mode or override.mode == "compile" then
        export.mode = override.export_mode or override.mode
    end
    if override.profile then
        export.mode = override.export_mode or "profile"
        export.profile = override.profile
    end
    if override.provider then
        export.mode = override.export_mode or "provider"
        export.provider = override.provider
    end
    if override.output_format or override.format then
        export.output_format = override.output_format or override.format
    end
    if override.output_name then
        export.output_name = override.output_name
    end
    if override.output_dir then
        export.output_dir = override.output_dir
    end
    if override.extra_args then
        export.extra_args = vim.deepcopy(override.extra_args)
    end
    return export
end

function M.effective(target, opts)
    return apply_overrides(
        inherited_export(config.unsafe_get().preview or {}, target),
        opts
    )
end

local function default_output_dir(preview)
    local browser = preview.browser or {}
    local base = browser.output_dir or xdg.preview_output_dir()
    return util.join(base, "exports")
end

local function default_output_name(project, export)
    if export.output_name and export.output_name ~= "" then
        return export.output_name
    end
    return ("%s-%s"):format(
        util.stem(project.main),
        session.project_id(project)
    )
end

local function export_opts(project, target, export)
    local opts = {
        profile = export.profile,
        provider = export.provider,
        format = export.output_format,
        output_name = export.output_name,
        output_dir = export.output_dir,
        extra_args = vim.deepcopy(export.extra_args or {}),
        update_compiler_output = false,
        producer = "preview",
        preview = true,
        preview_target = target,
        preview_export = true,
        preview_export_mode = export.mode,
    }

    if export.mode == "profile" then
        if not export.profile or export.profile == "" then
            return nil,
                {
                    ok = false,
                    reason = "missing_preview_profile",
                    message = "preview.export.profile is required when mode is profile",
                    target = target,
                }
        end
    elseif export.mode == "provider" then
        if export.provider == nil then
            return nil,
                {
                    ok = false,
                    reason = "missing_preview_provider",
                    message = "preview.export.provider is required when mode is provider",
                    target = target,
                }
        end
    end

    if not opts.output_dir then
        opts.output_dir = default_output_dir(config.unsafe_get().preview or {})
        opts.output_name = default_output_name(project, export)
    end

    return opts
end

local function readable(path)
    return type(path) == "string"
        and path ~= ""
        and vim.fn.filereadable(path) == 1
end

local function artifact_candidates(result)
    if type(result) ~= "table" then
        return {}
    end

    local candidates = {}
    if readable(result.path) then
        candidates[#candidates + 1] = {
            path = result.path,
            format = result.format or vim.fn.fnamemodify(result.path, ":e"),
        }
    end
    if readable(result.output) then
        candidates[#candidates + 1] = {
            path = result.output,
            format = result.format or vim.fn.fnamemodify(result.output, ":e"),
        }
    end

    local artifacts = result.artifacts or result.outputs
    if type(artifacts) == "table" then
        for _, artifact in ipairs(artifacts) do
            if type(artifact) == "table" and readable(artifact.path) then
                candidates[#candidates + 1] = {
                    path = artifact.path,
                    format = artifact.format
                        or vim.fn.fnamemodify(artifact.path, ":e"),
                    artifact = artifact,
                }
            end
        end
    end

    return candidates
end

local function select_artifact(result, export)
    local candidates = artifact_candidates(result)
    if #candidates == 0 then
        return nil,
            {
                ok = false,
                reason = "missing_preview_export",
                message = "Preview export did not produce a readable artifact",
                export_result = result,
            }
    end

    if export.output_format then
        for _, candidate in ipairs(candidates) do
            if candidate.format == export.output_format then
                return candidate
            end
        end
        return nil,
            {
                ok = false,
                reason = "missing_preview_export_format",
                message = ("Preview export did not produce a %s artifact"):format(
                    export.output_format
                ),
                export_result = result,
            }
    end

    if #candidates > 1 then
        return nil,
            {
                ok = false,
                reason = "ambiguous_preview_export",
                message = "Preview export produced multiple artifacts; set preview.export.output_format",
                export_result = result,
            }
    end

    return candidates[1]
end

local function summary(export, target)
    return {
        mode = export.mode,
        target = target,
        profile = export.profile,
        provider = provider_label(export.provider),
        output_format = export.output_format,
        output_name = export.output_name,
        output_dir = export.output_dir,
        extra_args = vim.deepcopy(export.extra_args or {}),
    }
end

local function resolved(project, target, export, path, result)
    local item = {
        ok = true,
        pending = false,
        path = path,
        output = path,
        export = summary(export, target),
        export_result = result,
    }
    log.add("debug", "preview export resolved", {
        main = project.main,
        target = target,
        mode = export.mode,
        output = path,
    })
    return item
end

local function failed(project, export, target, result)
    local payload = vim.tbl_extend("force", {
        ok = false,
        pending = false,
        target = target,
        export = summary(export, target),
    }, type(result) == "table" and result or {
        reason = "preview_export_failed",
        message = tostring(result),
    })
    log.add("warn", "preview export failed", {
        main = project.main,
        target = target,
        mode = export.mode,
        reason = payload.reason,
        message = payload.message,
    })
    return payload
end

local function wrap_pending(export_handle, complete)
    local handle = pending_handle.new({
        kind = "preview-export",
        handle = export_handle,
        complete = function(raw)
            return complete(raw)
        end,
    })

    return handle, handle.finish
end

--- Resolve the artifact path a native preview target should display.
---@param project table Project state.
---@param target string Preview target, usually `viewer` or `browser`.
---@param callback? fun(result:table) Completion callback for async exports.
---@param opts? table Runtime export overrides.
---@return table result Resolved path payload, failure payload, or pending handle.
function M.resolve(project, target, callback, opts)
    target = target or "viewer"
    local export = M.effective(target, opts)
    export.mode = export.mode or "compile"

    if export.mode == "compile" then
        return resolved(project, target, export, output_path(project))
    end

    local opts, opts_error = export_opts(project, target, export)
    if opts_error then
        return failed(project, export, target, opts_error)
    end
    export.output_dir = opts.output_dir
    export.output_name = opts.output_name

    local completed = false
    local completed_result = nil
    local pending_finish = nil
    local function complete(raw)
        if completed then
            return completed_result
        end
        completed = true
        if type(raw) == "table" and raw.ok == false then
            completed_result = failed(project, export, target, raw)
        else
            local artifact, artifact_error = select_artifact(raw, export)
            if not artifact then
                completed_result =
                    failed(project, export, target, artifact_error)
            else
                completed_result =
                    resolved(project, target, export, artifact.path, raw)
                preview_cache.prune(project, {
                    keep_paths = { artifact.path },
                }, noop)
            end
        end
        if callback then
            callback(completed_result)
        end
        return completed_result
    end

    local export_handle = operations.export(project, opts, function(result)
        if pending_finish then
            pending_finish(result)
        else
            complete(result)
        end
    end, noop)

    if completed then
        return completed_result
    end

    if type(export_handle) == "table" and export_handle.pending == true then
        local pending
        pending, pending_finish = wrap_pending(export_handle, complete)
        return pending
    end

    return complete(export_handle)
end

return M
