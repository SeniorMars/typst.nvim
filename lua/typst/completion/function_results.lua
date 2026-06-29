local completion_project = require("typst.completion.project")
local parameter_format = require("typst.completion.parameter_format")
local metadata = require("typst.metadata")
local symbol_search = require("typst.metadata.symbol_search")

local M = {}

local function stdlib_function_result(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end

    local display_name = name
    local path = name:gsub("^std%.", ""):gsub("^math%.", "")
    local item = metadata.stdlib_item(path)
    if
        not item
        or (item.kind ~= "function" and item.kind ~= "element")
        or type(item.parameters) ~= "table"
        or #item.parameters == 0
    then
        return nil
    end

    return {
        id = "stdlib." .. item.path,
        kind = "function",
        item_kind = item.kind,
        name = item.name or item.path,
        path = item.path,
        qualified_name = display_name,
        title = item.title or item.name or item.path,
        signature = parameter_format.stdlib_signature(item, display_name),
        parameters = vim.deepcopy(item.parameters),
        returns = item.returns,
        category = item.category,
        deprecated = item.deprecated,
        provider = "stdlib",
        provider_name = "Typst standard library metadata",
        semantic = false,
    }
end

function M.function_result(bufnr, name, row)
    local result = completion_project.function_result(bufnr, name, row)
    if result then
        return result
    end

    result = name and symbol_search.lookup(name) or nil
    if result and result.kind == "function" then
        return result
    end

    return stdlib_function_result(name)
end

function M.result_for_call_context(result, call_context)
    if not result or not call_context or call_context.set_rule ~= true then
        return result
    end

    local filtered = vim.deepcopy(result)
    filtered.parameters = {}
    for _, param in ipairs(result.parameters or {}) do
        if param.settable then
            filtered.parameters[#filtered.parameters + 1] = vim.deepcopy(param)
        end
    end

    filtered.set_rule = true
    filtered.signature = parameter_format.signature_from_parameters(
        result.qualified_name or result.name,
        filtered.parameters
    )
    return filtered
end

function M.find_parameter(result, name)
    if type(result) ~= "table" or type(name) ~= "string" then
        return nil
    end

    for _, param in ipairs(result.parameters or {}) do
        if param.name == name then
            return param
        end
    end
end

return M
