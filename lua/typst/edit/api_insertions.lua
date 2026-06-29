local insert = require("typst.edit.insert")

local M = {}

--- Attach insertion helpers to the edit API table.
---@param api table Edit API table mutated in place.
function M.attach(api)
    function api.insert(kind, action_opts)
        return insert.insert(kind, action_opts)
    end

    function api.insert_strong(action_opts)
        return insert.strong(action_opts)
    end

    function api.insert_emph(action_opts)
        return insert.emph(action_opts)
    end

    function api.insert_math(action_opts)
        return insert.math(action_opts)
    end

    function api.insert_content(action_opts)
        return insert.content(action_opts)
    end

    function api.insert_code(action_opts)
        return insert.code(action_opts)
    end

    function api.insert_raw(action_opts)
        return insert.raw(action_opts)
    end
end

return M
