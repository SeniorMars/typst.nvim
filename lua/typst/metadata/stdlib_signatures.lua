local metadata_artifacts = require("typst.metadata.artifacts")

local M = {}

local PARAM_POSITIONAL = 1
local PARAM_NAMED = 2
local PARAM_REQUIRED = 4
local PARAM_VARIADIC = 8
local PARAM_SETTABLE = 16

local SIGNATURE_SCHEMA = metadata_artifacts.schemas.signatures
local SIGNATURE_DOCS_SCHEMA = metadata_artifacts.schemas.signature_docs
local decode_mpack_runtime = metadata_artifacts.decode_mpack_runtime
local expect_table = metadata_artifacts.expect_table
local expect_array_len = metadata_artifacts.expect_array_len
local expect_artifact = metadata_artifacts.expect_artifact
local validate_string_array = metadata_artifacts.validate_string_array
local validate_artifact_count = metadata_artifacts.validate_artifact_count
local artifact_file = metadata_artifacts.artifact_file
local artifact_cache = metadata_artifacts.artifact_cache
local metadata_error = metadata_artifacts.error

local function has_flag(value, flag)
    value = value or 0
    return math.floor(value / flag) % 2 == 1
end

local function str(strings, id)
    if type(id) ~= "number" or id == 0 then
        return nil
    end
    return strings[id]
end

local function load_signatures(version)
    local artifacts = artifact_cache(version)
    if artifacts.signatures then
        return artifacts.signatures
    end

    local raw = expect_artifact(
        decode_mpack_runtime(artifact_file(version, "signatures")),
        "signatures",
        version,
        SIGNATURE_SCHEMA,
        6
    )
    validate_string_array(
        expect_table(raw[3], "signatures.strings"),
        "signatures.strings"
    )
    for index, row in ipairs(expect_table(raw[4], "signatures.inputs")) do
        expect_table(row, ("signatures.inputs[%d]"):format(index))
        local kind = row[1]
        if type(kind) ~= "number" then
            metadata_error(
                ("signatures.inputs[%d] missing input kind"):format(index)
            )
        end
        local expected_fields = ({ [1] = 1, [2] = 4, [3] = 4, [4] = 2 })[kind]
        if not expected_fields then
            metadata_error(
                ("signatures.inputs[%d] has unknown input kind %s"):format(
                    index,
                    tostring(kind)
                )
            )
        end
        expect_array_len(
            row,
            expected_fields,
            ("signatures.inputs[%d]"):format(index)
        )
        if kind == 4 then
            expect_table(
                row[2],
                ("signatures.inputs[%d].children"):format(index)
            )
        end
    end
    for index, row in ipairs(expect_table(raw[5], "signatures.defaults")) do
        expect_array_len(row, 2, ("signatures.defaults[%d]"):format(index))
    end
    for index, row in ipairs(expect_table(raw[6], "signatures.signatures")) do
        expect_array_len(row, 2, ("signatures.signatures[%d]"):format(index))
        expect_table(
            row[2],
            ("signatures.signatures[%d].parameters"):format(index)
        )
        for param_index, param in ipairs(row[2]) do
            expect_array_len(
                param,
                4,
                ("signatures.signatures[%d].parameters[%d]"):format(
                    index,
                    param_index
                )
            )
        end
    end
    validate_artifact_count(version, "signatures", #raw[6])
    artifacts.signatures = {
        schema = raw[1],
        version = raw[2],
        strings = raw[3] or {},
        inputs = raw[4] or {},
        defaults = raw[5] or {},
        signatures = raw[6] or {},
        input_cache = {},
        default_cache = {},
        signature_cache = {},
    }
    return artifacts.signatures
end

local function load_signature_docs(version)
    local artifacts = artifact_cache(version)
    if artifacts.signature_docs then
        return artifacts.signature_docs
    end

    local ok, raw =
        pcall(decode_mpack_runtime, artifact_file(version, "signature_docs"))
    if not ok then
        artifacts.signature_docs = {
            schema = 0,
            version = version,
            by_path = {},
        }
        return artifacts.signature_docs
    end

    raw = expect_artifact(
        raw,
        "signature_docs",
        version,
        SIGNATURE_DOCS_SCHEMA,
        4
    )
    local strings = expect_table(raw[3], "signature_docs.strings")
    local rows = expect_table(raw[4], "signature_docs.rows")
    validate_string_array(strings, "signature_docs.strings")
    validate_artifact_count(version, "signature_docs", #rows)
    local by_path = {}
    for row_index, row in ipairs(rows) do
        expect_array_len(row, 2, ("signature_docs.rows[%d]"):format(row_index))
        expect_table(
            row[2],
            ("signature_docs.rows[%d].params"):format(row_index)
        )
        local path = str(strings, row[1])
        if path then
            local docs = {}
            for param_index, param in ipairs(row[2]) do
                expect_array_len(
                    param,
                    2,
                    ("signature_docs.rows[%d].params[%d]"):format(
                        row_index,
                        param_index
                    )
                )
                local name = str(strings, param[1])
                local text = str(strings, param[2])
                if name and text then
                    docs[name] = text
                end
            end
            by_path[path] = docs
        end
    end

    artifacts.signature_docs = {
        schema = raw[1],
        version = raw[2],
        by_path = by_path,
    }
    return artifacts.signature_docs
end

local function expand_input(signatures, id)
    if type(id) ~= "number" or id == 0 then
        return nil
    end
    if signatures.input_cache[id] then
        return signatures.input_cache[id]
    end

    local row = signatures.inputs[id]
    if type(row) ~= "table" then
        return nil
    end

    local kind = row[1]
    local result
    if kind == 1 then
        result = { kind = "any" }
    elseif kind == 2 then
        result = {
            kind = "value",
            repr = str(signatures.strings, row[2]),
            type = str(signatures.strings, row[3]),
            docs = str(signatures.strings, row[4]),
        }
    elseif kind == 3 then
        result = {
            kind = "type",
            name = str(signatures.strings, row[2]),
            long_name = str(signatures.strings, row[3]),
            title = str(signatures.strings, row[4]),
        }
    elseif kind == 4 then
        result = { kind = "union", values = {} }
        for _, child_id in ipairs(row[2] or {}) do
            local child = expand_input(signatures, child_id)
            if child then
                result.values[#result.values + 1] = child
            end
        end
    else
        result = { kind = "unknown" }
    end

    signatures.input_cache[id] = result
    return result
end

local function expand_default(signatures, id)
    if type(id) ~= "number" or id == 0 then
        return nil
    end
    if signatures.default_cache[id] then
        return signatures.default_cache[id]
    end

    local row = signatures.defaults[id]
    if type(row) ~= "table" then
        return nil
    end

    local result = {
        repr = str(signatures.strings, row[1]),
        type = str(signatures.strings, row[2]),
    }
    signatures.default_cache[id] = result
    return result
end

function M.expand_id(version, id)
    if type(id) ~= "number" or id == 0 then
        return nil
    end

    local signatures = load_signatures(version)
    if signatures.signature_cache[id] then
        return signatures.signature_cache[id]
    end

    local row = signatures.signatures[id]
    if type(row) ~= "table" then
        return nil
    end

    local params = {}
    for _, param in ipairs(row[2] or {}) do
        local flags = param[2] or 0
        params[#params + 1] = {
            name = str(signatures.strings, param[1]),
            positional = has_flag(flags, PARAM_POSITIONAL),
            named = has_flag(flags, PARAM_NAMED),
            required = has_flag(flags, PARAM_REQUIRED),
            variadic = has_flag(flags, PARAM_VARIADIC),
            settable = has_flag(flags, PARAM_SETTABLE),
            input = expand_input(signatures, param[3]),
            default = expand_default(signatures, param[4]),
            docs = str(signatures.strings, param[5]),
        }
    end

    local result = {
        returns = expand_input(signatures, row[1]),
        parameters = params,
    }
    signatures.signature_cache[id] = result
    return result
end

function M.param_docs(version, path, name)
    local docs = load_signature_docs(version).by_path[path]
    return docs and docs[name] or nil
end

return M
