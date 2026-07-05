local operation = require("typst.core.operation")
local semver = require("typst.core.semver")
local util = require("typst.core.util")

local M = {}

local fallback_versions = { "0.14.2", "0.15.0" }

-- Versioned Typst metadata artifacts bundled with the plugin.
--
-- Consumers ask for "the current Typst metadata", but the runtime binary may be
-- older/newer than the bundled data. Select the newest compatible artifact and
-- validate schemas before exposing symbols or stdlib signatures.
M.schemas = {
    manifest = 2,
    symbols = 1,
    shorthands = 1,
    stdlib_index = 1,
    signatures = 2,
    signature_docs = 1,
}

local cache = {
    versions = nil,
    manifest = {},
    artifacts = {},
}

local version_detection_cache = {}
local version_detection_jobs = {}

local function runtime_file(path)
    local matches = vim.api.nvim_get_runtime_file(path, false)
    if not matches[1] then
        error(("typst.nvim: missing Typst metadata file %s"):format(path))
    end
    return matches[1]
end

local function read_file(path, mode)
    local file, err = io.open(path, mode or "r")
    if not file then
        error(("typst.nvim: failed to open %s: %s"):format(path, err))
    end

    local contents = file:read("*a")
    file:close()
    return contents
end

function M.decode_json_runtime(path)
    return vim.json.decode(read_file(runtime_file(path), "r"))
end

function M.decode_mpack_runtime(path)
    return vim.mpack.decode(read_file(runtime_file(path), "rb"))
end

function M.error(message)
    error("typst.nvim: invalid Typst metadata: " .. message)
end

function M.expect_table(value, label)
    if type(value) ~= "table" then
        M.error(label .. " must be a table")
    end
    return value
end

function M.expect_string(value, label)
    if type(value) ~= "string" or value == "" then
        M.error(label .. " must be a non-empty string")
    end
    return value
end

function M.expect_number(value, label)
    if type(value) ~= "number" then
        M.error(label .. " must be a number")
    end
    return value
end

function M.expect_array_len(value, length, label)
    M.expect_table(value, label)
    if #value ~= length then
        M.error(("%s must have %d fields"):format(label, length))
    end
    return value
end

function M.expect_artifact(raw, artifact, version, schema, field_count)
    M.expect_table(raw, artifact)
    if raw[1] ~= schema then
        M.error(("%s schema must be %d"):format(artifact, schema))
    end
    if raw[2] ~= version then
        M.error(("%s Typst version must be %s"):format(artifact, version))
    end
    for index = 1, field_count do
        if raw[index] == nil then
            M.error(("%s missing field %d"):format(artifact, index))
        end
    end
    if #raw ~= field_count then
        M.error(("%s must have %d fields"):format(artifact, field_count))
    end
    return raw
end

function M.validate_string_array(values, label)
    M.expect_table(values, label)
    for index, value in ipairs(values) do
        if type(value) ~= "string" then
            M.error(("%s[%d] must be a string"):format(label, index))
        end
    end
end

local function validate_artifact_file(file, label)
    if file:find("%z") or file:match("^[/\\]") or file:match("^%a:[/\\]") then
        M.error(label .. " must be a relative artifact path")
    end

    for segment in file:gmatch("[^/\\]+") do
        if segment == ".." then
            M.error(label .. " must not contain parent directory segments")
        end
    end
end

function M.load_versions()
    if cache.versions then
        return cache.versions
    end

    local ok, decoded =
        pcall(M.decode_json_runtime, "data/typst/metadata/versions.json")
    if
        ok
        and type(decoded) == "table"
        and type(decoded.versions) == "table"
    then
        local versions = {}
        for _, version in ipairs(decoded.versions) do
            if type(version) == "string" and version ~= "" then
                versions[#versions + 1] = version
            end
        end
        cache.versions = #versions > 0 and versions or fallback_versions
    else
        cache.versions = fallback_versions
    end

    return cache.versions
end

local function newest_available()
    local versions = M.load_versions() or {}
    return semver.newest(versions)
end

function M.detect_typst_version(executable)
    local key = table.concat(util.command_prefix(executable), "\0")
    local cached = version_detection_cache[key]
    if cached ~= nil then
        return cached or nil
    end
    version_detection_cache[key] = false

    if vim.fn.executable(util.command_executable(executable)) ~= 1 then
        return nil
    end

    local command = util.command_prefix(executable)
    command[#command + 1] = "--version"

    -- Version detection is async and intentionally returns nil on the first
    -- call. Completion can use bundled fallback metadata immediately and pick
    -- the detected version on a later request.
    local job = operation.run(
        "metadata-typst-version",
        command,
        { text = true },
        {
            timeout_ms = 1000,
        }
    )
    version_detection_jobs[key] = job
    job:on_finish(function(result)
        if version_detection_jobs[key] == job then
            version_detection_jobs[key] = nil
        end
        local version = nil
        if result and result.code == 0 then
            version = (result.stdout or ""):match("typst%s+([%d%.]+)")
        end
        version_detection_cache[key] = version or false
    end)
    return nil
end

function M.choose_version(requested)
    local versions = M.load_versions() or {}
    if not requested then
        return newest_available(), true
    end

    for _, version in ipairs(versions) do
        if version == requested then
            return version, false
        end
    end

    local compatible = nil
    for _, version in ipairs(versions) do
        if
            semver.compare(version, requested) <= 0
            and (not compatible or semver.compare(compatible, version) < 0)
        then
            compatible = version
        end
    end

    return compatible or newest_available(), true
end

function M.manifest(version)
    if not cache.manifest[version] then
        local decoded = M.expect_table(
            M.decode_json_runtime(
                ("data/typst/metadata/%s/manifest.json"):format(version)
            ),
            "manifest"
        )
        if decoded.schema ~= M.schemas.manifest then
            M.error(("manifest schema must be %d"):format(M.schemas.manifest))
        end
        if decoded.typst_version ~= version then
            M.error(("manifest Typst version must be %s"):format(version))
        end
        M.expect_number(decoded.generator_version, "manifest.generator_version")
        local manifest_artifacts =
            M.expect_table(decoded.artifacts, "manifest.artifacts")
        for name, schema in pairs({
            symbols = M.schemas.symbols,
            emojis = M.schemas.symbols,
            shorthands = M.schemas.shorthands,
            stdlib_index = M.schemas.stdlib_index,
            signatures = M.schemas.signatures,
            signature_docs = M.schemas.signature_docs,
        }) do
            local artifact = M.expect_table(
                manifest_artifacts[name],
                "manifest.artifacts." .. name
            )
            M.expect_string(
                artifact.file,
                "manifest.artifacts." .. name .. ".file"
            )
            validate_artifact_file(
                artifact.file,
                "manifest.artifacts." .. name .. ".file"
            )
            if artifact.schema ~= schema then
                M.error(
                    ("manifest.artifacts.%s.schema must be %d"):format(
                        name,
                        schema
                    )
                )
            end
            M.expect_number(
                artifact.count,
                "manifest.artifacts." .. name .. ".count"
            )
            M.expect_number(
                artifact.bytes,
                "manifest.artifacts." .. name .. ".bytes"
            )
        end
        M.expect_table(decoded.enums, "manifest.enums")
        cache.manifest[version] = decoded
    end
    return cache.manifest[version]
end

local function manifest_artifact(version, artifact)
    local item = M.manifest(version).artifacts
        and M.manifest(version).artifacts[artifact]
    if not item or type(item.file) ~= "string" then
        error(
            ("typst.nvim: missing Typst metadata artifact %s for %s"):format(
                artifact,
                version
            )
        )
    end
    return item
end

function M.artifact_file(version, artifact)
    return ("data/typst/metadata/%s/%s"):format(
        version,
        manifest_artifact(version, artifact).file
    )
end

function M.validate_artifact_count(version, artifact, actual)
    local expected = manifest_artifact(version, artifact).count
    if expected ~= actual then
        M.error(
            ("%s count must be %d, got %d"):format(artifact, expected, actual)
        )
    end
end

function M.artifact_cache(version)
    cache.artifacts[version] = cache.artifacts[version] or {}
    return cache.artifacts[version]
end

function M.reset()
    for _, job in pairs(version_detection_jobs) do
        job:cancel({ timeout_ms = 0, kill_timeout_ms = 0 })
    end
    cache = {
        versions = nil,
        manifest = {},
        artifacts = {},
    }
    version_detection_cache = {}
    version_detection_jobs = {}
end

return M
