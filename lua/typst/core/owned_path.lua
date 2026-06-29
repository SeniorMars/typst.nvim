local path_util = require("typst.core.path")

local M = {}

local uv = vim.uv or vim.loop

local function delete_checked(path, flags)
    local ok, result
    if flags ~= nil then
        ok, result = pcall(vim.fn.delete, path, flags)
    else
        ok, result = pcall(vim.fn.delete, path)
    end
    if not ok then
        return false, result
    end
    if result ~= 0 then
        return false, ("delete returned %s"):format(vim.inspect(result))
    end
    return true
end

local function owned_tree_allowed(path, opts)
    local allow = opts.allow
    if allow == true then
        return true
    end
    if type(allow) == "function" then
        local ok, result = pcall(allow, path)
        return ok and result == true
    end
    if type(opts.sentinel) == "string" and opts.sentinel ~= "" then
        return vim.fn.filereadable(opts.sentinel) == 1
    end
    if type(opts.sentinel_name) == "string" and opts.sentinel_name ~= "" then
        return vim.fn.filereadable(path_util.join(path, opts.sentinel_name))
            == 1
    end
    return false
end

--- Check whether a directory tree is safe to treat as plugin-owned.
---
--- This centralizes the invariants for recursive cleanup of generated trees:
--- no empty paths, no symlink roots, no project-root deletion unless opted in,
--- and explicit ownership proof through a policy callback or sentinel.
---@param path string Directory path to inspect.
---@param opts? table Ownership policy.
---@return boolean ok True when the path is safe or absent.
---@return table result Normalized result or refusal payload.
function M.check_tree(path, opts)
    opts = opts or {}
    if type(path) ~= "string" or path == "" then
        return false,
            {
                reason = "invalid_path",
                message = "owned-tree delete requires a non-empty path",
                path = path,
            }
    end

    local expanded = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
    local stat = uv.fs_lstat and uv.fs_lstat(expanded) or nil
    if stat and stat.type == "link" then
        return false,
            {
                reason = "symlink_unsupported",
                message = "refusing to recursively delete a symlinked directory",
                path = expanded,
            }
    end

    local resolved = path_util.canonical(path)
    if opts.root then
        local root = path_util.canonical(opts.root)
        if not path_util.path_within(resolved, root) then
            return false,
                {
                    reason = "outside_root",
                    message = "refusing to delete a directory outside the allowed root",
                    path = resolved,
                    root = root,
                }
        end
        if path_util.same_path(resolved, root) and opts.allow_root ~= true then
            return false,
                {
                    reason = "root_refused",
                    message = "refusing to recursively delete the allowed root",
                    path = resolved,
                    root = root,
                }
        end
    end

    if vim.fn.isdirectory(resolved) ~= 1 then
        return true, { path = resolved, exists = false }
    end

    stat = uv.fs_lstat and uv.fs_lstat(resolved) or nil
    if stat and stat.type == "link" then
        return false,
            {
                reason = "symlink_unsupported",
                message = "refusing to recursively delete a symlinked directory",
                path = resolved,
            }
    end

    if not owned_tree_allowed(resolved, opts) then
        return false,
            {
                reason = opts.reason or "unsafe_owned_tree",
                message = opts.message
                    or "refusing to recursively delete a directory without ownership proof",
                path = resolved,
            }
    end

    return true, { path = resolved, exists = true }
end

--- Recursively delete a directory only after proving plugin ownership.
---@param path string Directory path to delete.
---@param opts? table Ownership policy.
---@return boolean ok True when the directory was removed or did not exist.
---@return table|string|nil error Error payload/message when refused or failed.
function M.delete_tree(path, opts)
    local ok, result = M.check_tree(path, opts)
    if not ok then
        return false, result
    end
    if result.exists == false then
        return true
    end
    return delete_checked(result.path, "rf")
end

M.delete_owned_tree = M.delete_tree

return M
