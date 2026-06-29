local output_policy = require("typst.core.output_policy")
local util = require("typst.core.util")

local M = {}

function M.sentinel_path(dir)
    return output_policy.render_cache_sentinel_path(dir)
end

function M.mark_owned_cache_dir(dir)
    return output_policy.mark_render_cache_dir(dir)
end

function M.safe_force_dir(dir)
    return output_policy.render_cache_owned(dir)
end

return M
