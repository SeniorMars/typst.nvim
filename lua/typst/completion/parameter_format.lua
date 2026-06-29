local completion_items = require("typst.completion.items")
local metadata = require("typst.metadata")

local M = {}

local first_paragraph = completion_items.first_paragraph
local item_info = completion_items.info

function M.input_label(input)
    if type(input) == "string" then
        return input
    end

    if type(input) ~= "table" then
        return nil
    end

    if input.kind == "any" then
        return "any"
    end

    if input.kind == "value" then
        return input.repr or input.type
    end

    if input.kind == "type" then
        return input.name or input.title or input.long_name
    end

    if input.kind == "union" then
        local values = {}
        for _, value in ipairs(input.values or {}) do
            local label = M.input_label(value)
            if label then
                values[#values + 1] = label
            end
        end
        if #values > 0 then
            return table.concat(values, " | ")
        end
    end

    return input.kind
end

function M.default_label(default)
    if type(default) == "string" then
        return default
    end

    if type(default) == "table" then
        return default.repr or default.type
    end
end

local function parameter_signature_part(param)
    local name = param.name
    if type(name) ~= "string" or name == "" then
        return nil
    end

    if param.variadic then
        name = ".." .. name
    end

    if param.named then
        local default = M.default_label(param.default)
        if default then
            return ("%s: %s"):format(name, default)
        end
        return name .. ":"
    end

    return name
end

function M.signature_from_parameters(display_name, parameters)
    local parts = {}
    for _, param in ipairs(parameters or {}) do
        local part = parameter_signature_part(param)
        if part then
            parts[#parts + 1] = part
        end
    end

    return ("%s(%s)"):format(display_name, table.concat(parts, ", "))
end

function M.stdlib_signature(item, display_name)
    return M.signature_from_parameters(
        display_name or item.path or item.name,
        item.parameters
    )
end

function M.parameter_item(param, result)
    local word = param.name .. ": "
    local provider = result.provider or "stdlib"
    local input = M.input_label(param.input)
    local default = M.default_label(param.default)
    local docs = param.docs
    if not docs and provider == "stdlib" then
        docs = metadata.stdlib_param_docs(
            result.path or (result.id or ""):gsub("^stdlib%.", ""),
            param.name
        )
    end
    return {
        word = word,
        abbr = param.name .. ":",
        menu = "[Typst parameter]",
        kind = "a",
        info = item_info({
            result.signature,
            input and ("Type: " .. input) or nil,
            default and ("Default: " .. default) or nil,
            first_paragraph(docs),
        }),
        user_data = {
            typst = {
                kind = "parameter",
                provider = provider,
                semantic = result.semantic == true,
                function_name = result.qualified_name or result.name,
                set_rule = result.set_rule == true,
                input = param.input,
                input_label = input,
                default = default,
                default_value = param.default,
                required = param.required,
                settable = param.settable == true,
                docs = docs,
            },
        },
    }
end

function M.strip_wrapping_quotes(value)
    if type(value) ~= "string" or #value < 2 then
        return value
    end

    local quote = value:sub(1, 1)
    if (quote == '"' or quote == "'") and value:sub(-1) == quote then
        return value:sub(2, -2)
    end

    return value
end

function M.value_item(candidate, info)
    local param = info.parameter or {}
    local result = info.result or {}
    local word = candidate.word
    if info.quoted then
        word = M.strip_wrapping_quotes(word)
        if
            candidate.word:sub(1, 1) == '"'
            and candidate.word:sub(-1) == '"'
        then
            word = word .. '"'
        end
    end

    return {
        word = word,
        abbr = candidate.abbr or M.strip_wrapping_quotes(candidate.word),
        menu = "[Typst parameter value]",
        kind = "v",
        info = item_info({
            result.signature,
            param.name and ("Parameter: " .. param.name) or nil,
            M.input_label(param.input) and ("Accepted: " .. M.input_label(
                param.input
            )) or nil,
            candidate.type and ("Type: " .. candidate.type) or nil,
            candidate.source and ("Source: " .. candidate.source) or nil,
            candidate.docs,
        }),
        user_data = {
            typst = {
                kind = "parameter_value",
                provider = result.provider or "stdlib",
                semantic = result.semantic == true,
                function_name = result.qualified_name or result.name,
                parameter_name = param.name,
                value = candidate.word,
                value_type = candidate.type,
                source = candidate.source,
                docs = candidate.docs,
            },
        },
    }
end

return M
