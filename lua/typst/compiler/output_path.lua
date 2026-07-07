local path_util = require("typst.core.path")
local xdg = require("typst.core.xdg")

local M = {}

-- Resolve compile/export output paths within safe roots.
--
-- `output_name` stays basename-only; callers that need directories must use
-- `output_dir` so this module can validate the destination explicitly.
local function invalid_output_name_reason(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    if value == "." or value == ".." then
        return "must be a file basename, not " .. value
    end
    if value:find("[/\\]") ~= nil then
        return "must be a basename; use output_dir for directories"
    end
    if value:find("%z") or value:find("[%c]") then
        return "must not contain NUL or control characters"
    end
    if path_util.is_windows() then
        if value:find("[%.%s]$") then
            return "must not end with a space or dot on Windows"
        end
        if value:find('[<>:"|?*]') then
            return "must not contain Windows-reserved characters"
        end

        local stem = (value:match("^[^%.]+") or value):upper()
        if
            stem == "CON"
            or stem == "PRN"
            or stem == "AUX"
            or stem == "NUL"
            or stem:match("^COM[1-9]$")
            or stem:match("^LPT[1-9]$")
        then
            return "must not be a Windows reserved device name"
        end
    end
    return nil
end

local function validate_output_name(value)
    local reason = invalid_output_name_reason(value)
    if reason then
        error(("typst.nvim: output_name %s"):format(reason))
    end
    return value
end

local function plugin_cache_root()
    return xdg.cache_dir()
end

local function output_dir_allowed(project, config, output_dir)
    -- Outputs default to the project or typst.nvim cache. External destinations
    -- are opt-in because later clean/watch code may treat the output as owned.
    if config.allow_external_output == true then
        return true
    end

    return path_util.path_within(output_dir, project.root)
        or path_util.path_within(output_dir, plugin_cache_root())
end

--- Resolve the output path for a Typst compile/export run.
---@param project table Project state with root and main file paths.
---@param config table Effective run configuration with output fields.
---@return string path Absolute output path.
function M.output_path(project, config)
    local format = config.output_format or "pdf"
    local output_name = config.output_name
    if not output_name or output_name == "" then
        output_name = path_util.stem(project.main) .. "." .. format
    else
        output_name = validate_output_name(output_name)
    end

    if vim.fn.fnamemodify(output_name, ":e") == "" then
        output_name = output_name .. "." .. format
    end
    validate_output_name(output_name)

    if config.output_dir and config.output_dir ~= "" then
        local output_dir =
            path_util.resolve_path(config.output_dir, project.root)
        if not output_dir_allowed(project, config, output_dir) then
            error(
                "typst.nvim: output_dir outside the project or typst.nvim cache requires allow_external_output = true"
            )
        end
        local resolved =
            path_util.normalize(path_util.join(output_dir, output_name))
        if
            config.allow_external_output ~= true
            and not path_util.path_within(resolved, output_dir)
        then
            error(
                "typst.nvim: output_name resolved outside output_dir; use a basename"
            )
        end
        return resolved
    end

    return path_util.join(path_util.dirname(project.main), output_name)
end

--- Resolve an output path without throwing across workflow/API boundaries.
---
--- `output_path()` remains strict for internal validation tests and call sites
--- that intentionally want assertion-style behavior. Compile/watch/export
--- workflows should use this helper so user config/path errors return through
--- the normal result/callback contract before any process or output lease is
--- created.
---@param project table Project state with root and main file paths.
---@param config table Effective run configuration with output fields.
---@param context? {operation?:string} Failure context.
---@return string? output Absolute output path when valid.
---@return TypstCompilerResult? result Structured failure when invalid.
function M.safe_output_path(project, config, context)
    local ok, output = pcall(function()
        return M.output_path(project, config)
    end)
    if ok then
        return output, nil
    end

    local operation = context and context.operation or "compile"
    local error_text = tostring(output)
    local user_error = error_text:match("(typst%.nvim: .*)") or error_text
    local message = ("Invalid Typst %s output path: %s"):format(
        operation,
        user_error
    )
    return nil,
        {
            ok = false,
            code = 1,
            stdout = "",
            stderr = message,
            reason = "output_path_invalid",
            message = message,
            error = error_text,
            stale = false,
        }
end

--- Validate an explicit provider-declared output path without throwing.
---
--- Generic providers may declare their own output path, but the destination is
--- still typst.nvim-owned for leases/cleanup. Keep the same external-output
--- policy as normal compile outputs unless `allow_external_output` is set.
---@param project table Project state with root and main file paths.
---@param config table Effective run configuration.
---@param output string Provider-declared output path.
---@param context? {operation?:string} Failure context.
---@return string? output Absolute output path when valid.
---@return TypstCompilerResult? result Structured failure when invalid.
function M.safe_explicit_output_path(project, config, output, context)
    local ok, resolved_or_err = pcall(function()
        if type(output) ~= "string" or output == "" then
            error("typst.nvim: explicit output path must be a non-empty string")
        end
        local resolved = path_util.resolve_path(output, project.root)
        local output_dir = path_util.dirname(resolved)
        if not output_dir_allowed(project, config or {}, output_dir) then
            error(
                "typst.nvim: explicit output outside the project or typst.nvim cache requires allow_external_output = true"
            )
        end
        return resolved
    end)
    if ok then
        return resolved_or_err, nil
    end

    local operation = context and context.operation or "compile"
    local error_text = tostring(resolved_or_err)
    local user_error = error_text:match("(typst%.nvim: .*)") or error_text
    local message = ("Invalid Typst %s output path: %s"):format(
        operation,
        user_error
    )
    return nil,
        {
            ok = false,
            code = 1,
            stdout = "",
            stderr = message,
            reason = "output_path_invalid",
            message = message,
            error = error_text,
            stale = false,
        }
end

return M
