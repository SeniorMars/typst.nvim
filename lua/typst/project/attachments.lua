local lifecycle_buffers = require("typst.project.lifecycle.buffers")

local M = {}

-- BufferAttachment boundary. Callers should route buffer hook installation,
-- setup reapplication, and buffer-local attachment cleanup through this facade
-- while the coordinator delegates to focused attachment modules.

function M.install(api, bufnr)
    return lifecycle_buffers.install(api, bufnr)
end

function M.reapply_attached_buffers()
    return lifecycle_buffers.reapply_attached_buffers()
end

function M.forget(bufnr, project_key)
    return lifecycle_buffers.forget(bufnr, project_key)
end

function M.reset()
    return lifecycle_buffers.reset()
end

return M
