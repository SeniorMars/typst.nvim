local path_util = require("typst.core.path")
local xdg = require("typst.core.xdg")

local M = {}

-- Resolve compile/export output paths within safe roots.
--
-- `output_name` stays basename-only; callers that need directories must use
-- `output_dir` so this module can validate the destination explicitly.
local function contains_separator(value)
    return type(value) == "string" and value:find("[/\\]") ~= nil
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
    elseif contains_separator(output_name) then
        error(
            "typst.nvim: output_name must be a basename; use output_dir for directories"
        )
    elseif vim.fn.fnamemodify(output_name, ":e") == "" then
        output_name = output_name .. "." .. format
    end

    if config.output_dir and config.output_dir ~= "" then
        local output_dir =
            path_util.resolve_path(config.output_dir, project.root)
        if not output_dir_allowed(project, config, output_dir) then
            error(
                "typst.nvim: output_dir outside the project or typst.nvim cache requires allow_external_output = true"
            )
        end
        return path_util.join(output_dir, output_name)
    end

    return path_util.join(path_util.dirname(project.main), output_name)
end

return M
