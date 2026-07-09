local log = require("typst.core.log")
local output_policy = require("typst.core.output_policy")
local files = require("typst.core.files")
local path_util = require("typst.core.path")
local planner = require("typst.workflows.render.planner")

local M = {}

function M.generated_source(project, source_path, reason)
    if
        not source_path
        or planner.virtual_source_path(source_path)
        or path_util.same_path(source_path, project.main)
        or vim.fn.filereadable(source_path) ~= 1
    then
        return false
    end

    local ok, err = files.delete_checked(source_path)
    if not ok then
        log.add("warn", "failed to delete Typst render source", {
            path = source_path,
            reason = reason,
            error = err,
        })
        return false
    end
    return true
end

function M.unremembered(result, project, reason)
    if not result or result.remembered then
        return
    end

    local cache_dir = result.path and path_util.dirname(result.path) or nil
    local deleted_output = result.path
        and vim.fn.filereadable(result.path) == 1
        and output_policy.delete_render_cache_file(cache_dir, result.path)
    local deleted_source =
        M.generated_source(project, result.source_path, reason)

    if deleted_output or deleted_source then
        log.add("debug", "removed unremembered render files", {
            kind = result.kind,
            path = result.path,
            source_path = result.source_path,
            reason = reason,
        })
    end
end

return M
