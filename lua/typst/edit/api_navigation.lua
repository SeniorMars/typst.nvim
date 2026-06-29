local matchparen = require("typst.edit.matchparen")
local motions = require("typst.edit.motions")
local textobjects = require("typst.edit.textobjects")

local M = {}

--- Attach navigation and textobject helpers to the edit API table.
---@param api table Edit API table mutated in place.
function M.attach(api)
    function api.next_heading(action_opts)
        return motions.next_heading(action_opts)
    end

    function api.previous_heading(action_opts)
        return motions.previous_heading(action_opts)
    end

    function api.next_heading_end(action_opts)
        return motions.next_heading_end(action_opts)
    end

    function api.previous_heading_end(action_opts)
        return motions.previous_heading_end(action_opts)
    end

    function api.next_block(action_opts)
        return motions.next_block(action_opts)
    end

    function api.previous_block(action_opts)
        return motions.previous_block(action_opts)
    end

    function api.next_block_end(action_opts)
        return motions.next_block_end(action_opts)
    end

    function api.previous_block_end(action_opts)
        return motions.previous_block_end(action_opts)
    end

    function api.next_equation(action_opts)
        return motions.next_equation(action_opts)
    end

    function api.previous_equation(action_opts)
        return motions.previous_equation(action_opts)
    end

    function api.next_equation_end(action_opts)
        return motions.next_equation_end(action_opts)
    end

    function api.previous_equation_end(action_opts)
        return motions.previous_equation_end(action_opts)
    end

    function api.next_raw_block(action_opts)
        return motions.next_raw_block(action_opts)
    end

    function api.previous_raw_block(action_opts)
        return motions.previous_raw_block(action_opts)
    end

    function api.next_comment(action_opts)
        return motions.next_comment(action_opts)
    end

    function api.previous_comment(action_opts)
        return motions.previous_comment(action_opts)
    end

    function api.match(action_opts)
        return matchparen.jump(action_opts)
    end

    function api.select_textobject(kind, part, action_opts)
        return textobjects.select(kind, part, action_opts)
    end
end

return M
