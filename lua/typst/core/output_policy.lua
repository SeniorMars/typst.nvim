local config = require("typst.config")
local files = require("typst.core.files")
local owned_path = require("typst.core.owned_path")
local path = require("typst.core.path")

local M = {}

local sentinels = {
    render_cache = ".typst-nvim-render-cache",
    fragment_source = ".typst-nvim-fragment-source",
}

local sentinel_text = {
    render_cache = "typst.nvim render cache",
    fragment_source = "typst.nvim fragment source directory",
}

local function sentinel_name(kind)
    return assert(sentinels[kind], "unknown typst.nvim output policy kind")
end

function M.sentinel_path(kind, dir)
    local name = sentinel_name(kind)
    return path.join(dir, name)
end

function M.mark_owned_tree(kind, dir)
    return files.writefile_checked(
        { sentinel_text[kind] or ("typst.nvim " .. kind) },
        M.sentinel_path(kind, dir)
    )
end

function M.render_cache_sentinel_path(dir)
    return M.sentinel_path("render_cache", dir)
end

function M.mark_render_cache_dir(dir)
    return M.mark_owned_tree("render_cache", dir)
end

function M.render_cache_owned(dir)
    return path.path_within(dir, config.default_render_output_dir())
        or vim.fn.filereadable(M.render_cache_sentinel_path(dir)) == 1
end

function M.render_cache_delete_opts(dir)
    return {
        allow = function(candidate)
            return M.render_cache_owned(candidate)
        end,
        sentinel = M.render_cache_sentinel_path(dir),
        reason = "unsafe_cache_dir",
        message = "Refusing to recursively delete a render cache directory that typst.nvim does not own",
    }
end

function M.delete_render_cache_dir(dir)
    return owned_path.delete_tree(dir, M.render_cache_delete_opts(dir))
end

function M.file_owned_by_tree(dir, target)
    return type(target) == "string"
        and target ~= ""
        and type(dir) == "string"
        and dir ~= ""
        and path.path_within(target, dir)
        and not path.same_path(target, dir)
end

function M.delete_owned_file(dir, target, opts)
    opts = opts or {}
    if not M.file_owned_by_tree(dir, target) then
        return false, opts.reason or "outside_owned_tree"
    end
    if vim.fn.filereadable(target) ~= 1 then
        return true
    end
    return files.delete_checked(target)
end

function M.delete_render_cache_file(dir, target)
    return M.delete_owned_file(dir, target, { reason = "outside_cache" })
end

function M.fragment_source_sentinel_path(dir)
    return M.sentinel_path("fragment_source", dir)
end

function M.mark_fragment_source_dir(dir)
    return M.mark_owned_tree("fragment_source", dir)
end

function M.fragment_source_auto_mark_allowed(dir, state)
    return false
end

function M.fragment_source_cleanup_allowed(dir, state)
    if type(dir) ~= "string" or dir == "" or not state or not state.root then
        return false, "invalid_fragment_source_dir"
    end

    local candidate = path.canonical(dir)
    local root = path.canonical(state.root)
    if not path.path_within(candidate, root) then
        return false, "outside_project"
    end
    if path.same_path(candidate, root) then
        return false, "unsafe_fragment_source_dir"
    end

    if vim.fn.filereadable(M.fragment_source_sentinel_path(candidate)) == 1 then
        return true
    end

    return false, "unsafe_fragment_source_dir"
end

function M.fragment_source_delete_opts(dir, state)
    local allowed, reason = M.fragment_source_cleanup_allowed(dir, state)
    return {
        allow = allowed,
        sentinel = M.fragment_source_sentinel_path(dir),
        reason = reason or "unsafe_fragment_source_dir",
        message = "Refusing to recursively delete a fragment source directory that typst.nvim does not own",
    }
end

function M.delete_fragment_source_dir(dir, state)
    return owned_path.delete_tree(
        dir,
        M.fragment_source_delete_opts(dir, state)
    )
end

return M
