local root_discovery = require("typst.project.root")
local util = require("typst.core.util")

local M = {}

---Resolve the initial project root candidate for a buffer path.
---@param path string Buffer or scratch path.
---@param bufnr integer Buffer being resolved.
---@param scratch boolean Whether `path` is a synthetic scratch path.
---@param opts table Plugin configuration.
---@return string root Root candidate.
---@return string source Root source label.
function M.initial(path, bufnr, scratch, opts)
    local root, root_source = root_discovery.detect(path, bufnr, opts)
    if scratch and root_source == "buffer directory" then
        return util.normalize(vim.fn.getcwd()), "unnamed buffer cwd"
    end
    return root or util.normalize(vim.fn.getcwd()), root_source or "cwd"
end

M.reconcile_for_main = root_discovery.reconcile_for_main

return M
