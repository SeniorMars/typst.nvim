local path = require("typst.core.path")

local M = {}

local namespace = "typst.nvim"

local function stdpath(kind)
    return vim.fn.stdpath(kind)
end

local function join_under(kind, ...)
    return path.join(stdpath(kind), namespace, ...)
end

function M.cache_dir(...)
    return join_under("cache", ...)
end

function M.state_dir(...)
    return join_under("state", ...)
end

function M.config_dir(...)
    return join_under("config", ...)
end

function M.output_dir()
    return M.cache_dir("output")
end

function M.fragments_output_dir()
    return M.cache_dir("fragments")
end

function M.render_output_dir()
    return M.cache_dir("render")
end

function M.render_source_dir()
    return M.cache_dir("render-sources")
end

function M.preview_output_dir()
    return M.cache_dir("preview")
end

return M
