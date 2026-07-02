local lifecycle_buffers = require("typst.project.lifecycle.buffers")

local M = {}

-- BufferAttachment boundary. The implementation still lives in the legacy
-- lifecycle buffer module, but callers should route buffer hook installation
-- and setup reapplication through this facade.

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
