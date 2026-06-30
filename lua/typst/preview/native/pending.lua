local pending_handle = require("typst.core.pending")
local preview_export = require("typst.preview.export")

local M = {}

function M.continuation(pending, continue)
    local handle = pending_handle.new({
        kind = "preview-native",
        handle = pending,
        complete = function(result)
            return continue(result)
        end,
    })
    local ok, err = pending_handle.subscribe(pending, handle.finish)
    if not ok then
        handle.finish({
            ok = false,
            reason = "pending_unobservable",
            message = tostring(err),
        }, "subscribe")
    end

    return handle
end

function M.with_output(project, target, opts, continue)
    local resolved = preview_export.resolve(project, target, nil, opts)
    if type(resolved) == "table" and resolved.pending == true then
        return M.continuation(resolved, continue)
    end
    return continue(resolved)
end

return M
