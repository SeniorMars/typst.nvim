local stdlib_core = require("typst.metadata.stdlib_core")
local stdlib_items = require("typst.metadata.stdlib_items")
local stdlib_signatures = require("typst.metadata.stdlib_signatures")

local M = {}

local KIND_SYMBOL = stdlib_core.KIND_SYMBOL
local CONTEXT_GLOBAL = stdlib_core.CONTEXT_GLOBAL
local CONTEXT_MATH = stdlib_core.CONTEXT_MATH
local has_flag = stdlib_core.has_flag
local starts_with = stdlib_core.starts_with
local lower_bound = stdlib_core.lower_bound
local str = stdlib_core.str
local load_stdlib_index = stdlib_core.load

function M.view(version)
    local index = load_stdlib_index(version)
    if index.view then
        return index.view
    end

    index.view = {
        schema = index.schema,
        version = index.version,
        global = stdlib_items.context_table(version, index, CONTEXT_GLOBAL),
        math = stdlib_items.context_table(version, index, CONTEXT_MATH),
        items = stdlib_items.items_table(version, index),
    }
    return index.view
end

function M.item(version, path)
    return stdlib_items.expand(version, load_stdlib_index(version), path)
end

function M.complete(version, prefix, context, opts)
    opts = opts or {}
    prefix = prefix or ""
    local context_bit = context == "math" and CONTEXT_MATH
        or context == "global" and CONTEXT_GLOBAL
        or nil
    local limit = opts.limit or math.huge
    local index = load_stdlib_index(version)
    local result = {}
    local path_index = prefix == "" and 1 or lower_bound(index.paths, prefix)
    while path_index <= #index.paths and #result < limit do
        local path = index.paths[path_index]
        if prefix ~= "" and not starts_with(path, prefix) then
            break
        end

        local row = index.rows[index.by_path[path]]
        if
            row
            and (not context_bit or has_flag(row[5] or 0, context_bit))
            and (not opts.direct_children or stdlib_core.direct_child(
                path,
                prefix
            ))
            and (not opts.exclude_symbols or row[3] ~= KIND_SYMBOL)
        then
            if opts.signatures or opts.full then
                result[#result + 1] = stdlib_items.expand(version, index, path)
            else
                result[#result + 1] = stdlib_items.row_summary(index, row)
            end
        end

        path_index = path_index + 1
    end
    return result
end

function M.param_docs(version, path, name)
    return stdlib_signatures.param_docs(version, path, name)
end

function M.constants_by_type(version, type_name, opts)
    opts = opts or {}
    local context_bit = opts.context == "math" and CONTEXT_MATH
        or opts.context == "global" and CONTEXT_GLOBAL
        or nil
    local index = load_stdlib_index(version)
    local cache_key = type_name .. "\0" .. tostring(context_bit or "")
    if index.constants_by_type[cache_key] then
        return vim.deepcopy(index.constants_by_type[cache_key])
    end

    local result = {}
    for _, path in ipairs(index.paths) do
        local row = index.rows[index.by_path[path]]
        if
            row
            and row[3] == 5
            and str(index.strings, row[9]) == type_name
            and (not context_bit or has_flag(row[5] or 0, context_bit))
        then
            result[#result + 1] = {
                path = path,
                name = str(index.strings, row[2]),
                type = type_name,
                repr = str(index.strings, row[10]) or path,
                category = str(index.strings, row[4]),
                version = version,
            }
        end
    end

    table.sort(result, function(left, right)
        return left.path < right.path
    end)
    index.constants_by_type[cache_key] = result
    return vim.deepcopy(result)
end

function M.signature(version, path)
    local item = M.item(version, path)
    if not item then
        return nil
    end
    return {
        parameters = item.parameters or {},
        returns = item.returns,
    }
end

return M
