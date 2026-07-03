local compile = require("typst.config.compile")
local conceal = require("typst.config.conceal")
local viewer = require("typst.config.viewer")

local M = {}

M.compile = compile.validate
M.viewer = viewer.validate
M.conceal = conceal.validate

--- Validate main-file resolution configuration.
---@param main any `main` configuration value.
function M.main(main)
    if main == nil or type(main) == "string" or type(main) == "function" then
        return
    end

    if type(main) ~= "table" then
        error("typst.nvim: main must be a string, function, table, or nil")
    end

    for root, value in pairs(main) do
        if type(root) ~= "string" or root == "" then
            error("typst.nvim: main table keys must be non-empty strings")
        end

        if type(value) ~= "string" and type(value) ~= "function" then
            error(
                ("typst.nvim: main[%s] must be a string or function"):format(
                    vim.inspect(root)
                )
            )
        end

        if type(value) == "string" and value == "" then
            error(
                ("typst.nvim: main[%s] must be a non-empty string"):format(
                    vim.inspect(root)
                )
            )
        end
    end
end

--- Validate project lifecycle configuration.
---@param project table `project` configuration section.
function M.project(project)
    if type(project) ~= "table" then
        error("typst.nvim: project must be a table")
    end

    if type(project.import_scan) ~= "boolean" then
        error("typst.nvim: project.import_scan must be a boolean")
    end

    if type(project.persist_main) ~= "boolean" then
        error("typst.nvim: project.persist_main must be a boolean")
    end

    if type(project.warn_on_low_confidence_main) ~= "boolean" then
        error(
            "typst.nvim: project.warn_on_low_confidence_main must be a boolean"
        )
    end

    if
        type(project.import_scan_max_files) ~= "number"
        or project.import_scan_max_files < 1
    then
        error(
            "typst.nvim: project.import_scan_max_files must be a positive number"
        )
    end

    if
        type(project.import_scan_max_depth) ~= "number"
        or project.import_scan_max_depth < 0
    then
        error(
            "typst.nvim: project.import_scan_max_depth must be a non-negative number"
        )
    end

    if
        type(project.import_scan_max_entries) ~= "number"
        or project.import_scan_max_entries < 1
    then
        error(
            "typst.nvim: project.import_scan_max_entries must be a positive number"
        )
    end

    if type(project.import_scan_skip_dirs) ~= "table" then
        error("typst.nvim: project.import_scan_skip_dirs must be a list")
    end
    for index, value in ipairs(project.import_scan_skip_dirs) do
        if type(value) ~= "string" or value == "" then
            error(
                ("typst.nvim: project.import_scan_skip_dirs[%d] must be a non-empty string"):format(
                    index
                )
            )
        end
        if value:find("[/\\]") then
            error(
                ("typst.nvim: project.import_scan_skip_dirs[%d] must be a directory name, not a path"):format(
                    index
                )
            )
        end
    end

    if project.index ~= nil and type(project.index) ~= "table" then
        error("typst.nvim: project.index must be a table or nil")
    end

    local index = project.index or {}
    if
        index.fs_watchers ~= nil
        and index.fs_watchers ~= false
        and index.fs_watchers ~= "auto"
        and (type(index.fs_watchers) ~= "number" or index.fs_watchers < 0)
    then
        error(
            'typst.nvim: project.index.fs_watchers must be "auto", false, or a non-negative number'
        )
    end

    if
        index.max_file_bytes ~= nil
        and (type(index.max_file_bytes) ~= "number" or index.max_file_bytes < 0)
    then
        error(
            "typst.nvim: project.index.max_file_bytes must be a non-negative number"
        )
    end

    if
        index.large_file_policy ~= nil
        and index.large_file_policy ~= "skip"
        and index.large_file_policy ~= "headings-only"
        and index.large_file_policy ~= "scan"
    then
        error(
            'typst.nvim: project.index.large_file_policy must be "skip", "headings-only", or "scan"'
        )
    end
end

return M
