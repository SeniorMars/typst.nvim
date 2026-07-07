local calls = require("typst.edit.calls")
local metadata = require("typst.metadata")
local ts = require("typst.core.treesitter")

local M = {}

local first_child = calls.first_child
local node_text = calls.node_text

local function parameters_from_node(bufnr, parameters)
    if not parameters then
        return nil, "unsupported_parameters"
    end

    local params = {}
    for _, child in ipairs(ts.children(parameters)) do
        local child_type = child:type()
        if child_type == "sink_parameter" or child_type == "elude" then
            return nil, "variadic_parameters"
        elseif
            child_type == "identifier"
            or child_type == "named_parameter"
        then
            local name = child_type == "identifier" and child
                or first_child(child, "identifier")
            if not name then
                return nil, "unsupported_parameters"
            end
            params[#params + 1] = node_text(bufnr, name)
        elseif
            child_type ~= "("
            and child_type ~= ")"
            and child_type ~= ","
        then
            return nil, "unsupported_parameters"
        end
    end

    if #params == 0 then
        return nil, "no_nameable_parameters"
    end
    return params, nil
end

local function local_function_parameters(bufnr, name, call)
    local root = ts.root(bufnr)
    if not root then
        return nil, "no_parser"
    end

    local call_range = call and ts.range(call) or nil
    local best = nil
    ts.walk(root, function(node)
        if node:type() ~= "let_binding" then
            return
        end

        local declaration_name = first_child(node, "identifier")
        local parameters = first_child(node, "parameters")

        if
            not declaration_name
            or node_text(bufnr, declaration_name) ~= name
        then
            return
        end

        if not parameters then
            return
        end

        local declaration_range = ts.range(node)
        if
            call_range
            and (
                declaration_range.start_row > call_range.start_row
                or (
                    declaration_range.start_row == call_range.start_row
                    and declaration_range.start_col >= call_range.start_col
                )
            )
        then
            return
        end

        if not best or declaration_range.start_row > best.range.start_row then
            best = {
                parameters = parameters,
                range = declaration_range,
            }
        end
    end)
    if not best then
        return nil, "no_parameter_metadata"
    end

    return parameters_from_node(bufnr, best.parameters)
end

local function stdlib_item_for_name(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    local candidates = { name }
    if name:sub(1, 4) == "std." then
        candidates[#candidates + 1] = name:sub(5)
    end

    for _, candidate in ipairs(candidates) do
        local item = metadata.stdlib_item(candidate)
        if item and type(item.parameters) == "table" then
            return item
        end
    end
end

local function stdlib_function_parameters(name)
    local item = stdlib_item_for_name(name)
    if not item then
        return nil, "no_parameter_metadata"
    end

    if item.kind ~= "function" and item.kind ~= "element" then
        return nil, "no_parameter_metadata"
    end

    local params = {}
    for _, param in ipairs(item.parameters or {}) do
        if param.positional then
            if param.variadic then
                if #params == 0 then
                    return nil, "variadic_parameters"
                end
                break
            end
            if not param.named then
                return nil, "positional_only_parameters"
            end
            if type(param.name) ~= "string" or param.name == "" then
                return nil, "unsupported_parameters"
            end
            params[#params + 1] = param.name
        end
    end

    if #params == 0 then
        return nil, "no_nameable_parameters"
    end

    return params, nil
end

function M.function_parameters(bufnr, name, call)
    local params, reason = local_function_parameters(bufnr, name, call)
    if params or reason ~= "no_parameter_metadata" then
        return params, reason
    end

    return stdlib_function_parameters(name)
end

return M
