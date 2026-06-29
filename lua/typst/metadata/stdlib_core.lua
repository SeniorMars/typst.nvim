local metadata_artifacts = require("typst.metadata.artifacts")

local M = {}

M.KIND = {
    [1] = "element",
    [2] = "function",
    [3] = "type",
    [4] = "module",
    [5] = "constant",
    [6] = "symbol",
}

M.KIND_SYMBOL = 6

M.CONTEXT_GLOBAL = 1
M.CONTEXT_MATH = 2

M.FLAG_CONTEXTUAL = 1
M.FLAG_DEPRECATED = 2
M.FLAG_HAS_CONSTRUCTOR = 4

local STDLIB_INDEX_SCHEMA = metadata_artifacts.schemas.stdlib_index
local decode_mpack_runtime = metadata_artifacts.decode_mpack_runtime
local expect_table = metadata_artifacts.expect_table
local expect_array_len = metadata_artifacts.expect_array_len
local expect_artifact = metadata_artifacts.expect_artifact
local validate_string_array = metadata_artifacts.validate_string_array
local validate_artifact_count = metadata_artifacts.validate_artifact_count
local artifact_file = metadata_artifacts.artifact_file
local artifact_cache = metadata_artifacts.artifact_cache

function M.has_flag(value, flag)
    value = value or 0
    return math.floor(value / flag) % 2 == 1
end

function M.starts_with(value, prefix)
    return type(value) == "string" and value:sub(1, #prefix) == prefix
end

function M.lower_bound(values, target)
    local low = 1
    local high = #values + 1
    while low < high do
        local mid = math.floor((low + high) / 2)
        if values[mid] < target then
            low = mid + 1
        else
            high = mid
        end
    end
    return low
end

function M.str(strings, id)
    if type(id) ~= "number" or id == 0 then
        return nil
    end
    return strings[id]
end

function M.context_names(bits)
    local result = {}
    if M.has_flag(bits, M.CONTEXT_GLOBAL) then
        result[#result + 1] = "global"
    end
    if M.has_flag(bits, M.CONTEXT_MATH) then
        result[#result + 1] = "math"
    end
    return result
end

function M.load(version)
    local artifacts = artifact_cache(version)
    if artifacts.stdlib_index then
        return artifacts.stdlib_index
    end

    local raw = expect_artifact(
        decode_mpack_runtime(artifact_file(version, "stdlib_index")),
        "stdlib_index",
        version,
        STDLIB_INDEX_SCHEMA,
        4
    )
    local rows = expect_table(raw[4], "stdlib_index.rows")
    local strings = expect_table(raw[3], "stdlib_index.strings")
    validate_string_array(strings, "stdlib_index.strings")
    validate_artifact_count(version, "stdlib_index", #rows)
    local by_path = {}
    local paths = {}
    for index, row in ipairs(rows) do
        expect_array_len(row, 14, ("stdlib_index.rows[%d]"):format(index))
        local path = M.str(strings, row[1])
        if path then
            by_path[path] = index
            paths[#paths + 1] = path
        end
    end
    table.sort(paths)

    artifacts.stdlib_index = {
        schema = raw[1],
        version = raw[2],
        strings = strings,
        rows = rows,
        paths = paths,
        by_path = by_path,
        item_cache = {},
        child_index = nil,
        constants_by_type = {},
        view = nil,
    }
    return artifacts.stdlib_index
end

function M.ensure_child_index(index)
    if index.child_index then
        return index.child_index
    end

    local child_index = {}
    for _, path in ipairs(index.paths) do
        local parent, child = path:match("^(.*)%.([^%.]+)$")
        if parent and child then
            child_index[parent] = child_index[parent] or {}
            child_index[parent][child] = path
        end
    end

    index.child_index = child_index
    return child_index
end

function M.direct_child(path, prefix)
    local suffix = prefix == "" and path or path:sub(#prefix + 1)
    return not suffix:find(".", 1, true)
end

return M
