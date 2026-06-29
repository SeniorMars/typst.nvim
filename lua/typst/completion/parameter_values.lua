local completion_items = require("typst.completion.items")
local metadata = require("typst.metadata")
local parameter_format = require("typst.completion.parameter_format")

local M = {}

local trim = completion_items.trim

local value_like_types = {
    auto = true,
    bool = true,
    none = true,
}

local stdlib_constant_value_types = {
    alignment = true,
    color = true,
    direction = true,
}

local function add_candidate(candidates, seen, word, fields)
    word = trim(word)
    if not word or seen[word] then
        return
    end

    seen[word] = true
    candidates[#candidates + 1] = vim.tbl_extend("force", fields or {}, {
        word = word,
        abbr = fields and fields.abbr
            or parameter_format.strip_wrapping_quotes(word),
    })
end

local function collect_input(input, candidates, seen)
    if type(input) ~= "table" then
        return
    end

    if input.kind == "value" then
        add_candidate(candidates, seen, input.repr, {
            kind = "value",
            type = input.type,
            abbr = parameter_format.strip_wrapping_quotes(input.repr),
            docs = input.docs,
        })
        return
    end

    if input.kind == "type" then
        if input.name == "bool" then
            add_candidate(candidates, seen, "false", {
                kind = "value",
                type = "bool",
            })
            add_candidate(candidates, seen, "true", {
                kind = "value",
                type = "bool",
            })
            return
        end

        if value_like_types[input.name] then
            add_candidate(candidates, seen, input.name, {
                kind = "value",
                type = input.name,
            })
            return
        end

        if stdlib_constant_value_types[input.name] then
            local ok, constants = pcall(
                metadata.stdlib_constants_by_type,
                input.name,
                { context = "global" }
            )
            if ok then
                for _, constant in ipairs(constants or {}) do
                    if not constant.path:find(".", 1, true) then
                        add_candidate(
                            candidates,
                            seen,
                            constant.repr or constant.path,
                            {
                                kind = "value",
                                type = constant.type or input.name,
                                source = constant.path,
                                abbr = constant.repr or constant.path,
                            }
                        )
                    end
                end
            end
            return
        end
    end

    if input.kind == "union" then
        for _, child in ipairs(input.values or {}) do
            collect_input(child, candidates, seen)
        end
    end
end

function M.candidates(input)
    local candidates = {}
    collect_input(input, candidates, {})
    return candidates
end

return M
