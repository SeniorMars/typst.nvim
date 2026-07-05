local config = require("typst.config")
local util = require("typst.core.util")

local M = {}

local optional_nil_defaults = {
    "metadata_version",
    "output_name",
    "root",
    "main",
    "project.import_scan_max_descendant_depth",
    "compile.provider",
    "exports.provider",
    "exports.default",
    "format.command",
    "grammar.command",
    "grammar.stdin",
    "grammar.file_arg",
    "integrations.tinymist.cmd",
    "integrations.tinymist.capabilities",
    "integrations.tinymist.on_attach",
    "lint.command",
    "log.file_path",
    "picker.custom",
    "render.provider",
    "render.display_provider",
    "viewer.open",
    "viewer.reload",
    "viewer.forward",
    "viewer.inverse",
    "preview.browser.export.output_dir",
    "preview.browser.export.output_format",
    "preview.browser.export.output_name",
    "preview.browser.export.profile",
    "preview.browser.export.provider",
    "preview.browser.app",
    "preview.browser.commands",
    "preview.browser.open",
    "preview.browser.style.css",
    "preview.browser.style.css_path",
    "preview.export.output_dir",
    "preview.export.output_format",
    "preview.export.output_name",
    "preview.export.profile",
    "preview.export.provider",
    "preview.open",
    "preview.stop",
    "preview.refresh",
    "preview.forward",
    "preview.inverse",
    "preview.source_maps.provider",
    "preview.source_maps.forward",
    "preview.source_maps.inverse",
    "folds.text",
}

local optional_types = {
    ["integrations.tinymist.capabilities"] = "nil|table",
    ["integrations.tinymist.on_attach"] = "nil|function",
    ["log.file_path"] = "nil|string",
    ["integrations.semantic.provider"] = "nil|string|function|table",
    ["compile.provider"] = "nil|string|function|table",
    ["exports.provider"] = "nil|string|function|table",
    ["render.provider"] = "nil|string|function|table",
    ["render.display_provider"] = "nil|string|function|table",
    ["viewer.open"] = "nil|string|function",
    ["viewer.reload"] = "nil|string|function",
    ["viewer.forward"] = "nil|string|function",
    ["viewer.inverse"] = "nil|string|function",
    ["preview.browser.export.output_dir"] = "nil|string",
    ["preview.browser.export.output_format"] = "nil|string",
    ["preview.browser.export.output_name"] = "nil|string",
    ["preview.browser.export.profile"] = "nil|string",
    ["preview.browser.export.provider"] = "nil|string|function|table",
    ["preview.browser.app"] = "nil|string",
    ["preview.browser.commands"] = "nil|list",
    ["preview.browser.open"] = "nil|function",
    ["preview.browser.style.css"] = "nil|string",
    ["preview.browser.style.css_path"] = "nil|string",
    ["preview.export.output_dir"] = "nil|string",
    ["preview.export.output_format"] = "nil|string",
    ["preview.export.output_name"] = "nil|string",
    ["preview.export.profile"] = "nil|string",
    ["preview.export.provider"] = "nil|string|function|table",
    ["preview.open"] = "nil|function",
    ["preview.stop"] = "nil|function",
    ["preview.refresh"] = "nil|function",
    ["preview.forward"] = "nil|function",
    ["preview.inverse"] = "nil|function",
    ["preview.source_maps.provider"] = "nil|string|function|table",
    ["preview.source_maps.forward"] = "nil|function",
    ["preview.source_maps.inverse"] = "nil|function",
    ["project.import_scan_max_descendant_depth"] = "nil|number",
    ["folds.text"] = "nil|string|function",
}

local type_overrides = {
    ["diagnostics.external_paths"] = "string",
    ["diagnostics.max_buffers_per_publish"] = "integer",
    ["integrations.semantic.provider"] = "nil|string|function|table",
    ["preview.browser.style.variables"] = "table",
    validation = "false|string",
}

local function sorted_keys(tbl)
    local keys = vim.tbl_keys(tbl or {})
    table.sort(keys, function(left, right)
        if type(left) == type(right) then
            return tostring(left) < tostring(right)
        end
        return type(left) < type(right)
    end)
    return keys
end

local function is_list(value)
    if type(value) ~= "table" then
        return false
    end

    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        count = math.max(count, key)
    end

    for index = 1, count do
        if value[index] == nil then
            return false
        end
    end
    return true
end

local function escape_string(value)
    return vim.json.encode(value)
end

local function symbolic_path(value)
    local cache = vim.fn.stdpath("cache")
    if type(value) == "string" and cache ~= "" then
        local normalized_value = util.normalize(value)
        local normalized_cache = util.normalize(cache)
        if normalized_value == normalized_cache then
            return 'vim.fn.stdpath("cache")'
        end
        local prefix = normalized_cache .. "/"
        if normalized_value:sub(1, #prefix) == prefix then
            return ('vim.fs.joinpath(vim.fn.stdpath("cache"), %s)'):format(
                table.concat(
                    vim.tbl_map(
                        escape_string,
                        vim.split(
                            normalized_value:sub(#prefix + 1),
                            "/",
                            { plain = true }
                        )
                    ),
                    ", "
                )
            )
        end
    end
end

local function scalar_default(value)
    local symbolic = symbolic_path(value)
    if symbolic then
        return symbolic
    end

    local value_type = type(value)
    if value_type == "string" then
        return escape_string(value)
    end
    if value_type == "boolean" or value_type == "number" then
        return tostring(value)
    end
    if value == nil then
        return "nil"
    end
    return ("<%s>"):format(value_type)
end

local function list_default(value)
    if #value == 0 then
        return "{}"
    end

    local parts = {}
    for index, item in ipairs(value) do
        if type(item) == "table" then
            parts[index] = "{ ... }"
        else
            parts[index] = scalar_default(item)
        end
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function default_type(value)
    if type(value) == "table" and is_list(value) then
        return "list"
    end
    return type(value)
end

local function entry(entries, path, value, value_type)
    entries[#entries + 1] = {
        path = path,
        type = value_type or type_overrides[path] or default_type(value),
        default = type(value) == "table" and (is_list(value) and list_default(
            value
        ) or "{ ... }") or scalar_default(value),
    }
end

local function flatten(entries, path, value)
    if type(value) ~= "table" then
        entry(entries, path, value)
        return
    end

    if is_list(value) then
        entry(entries, path, value, type_overrides[path] or "list")
        return
    end

    local keys = sorted_keys(value)
    if #keys == 0 then
        entry(entries, path, value, "table")
        return
    end

    for _, key in ipairs(keys) do
        local child_path = path == "" and tostring(key)
            or ("%s.%s"):format(path, tostring(key))
        flatten(entries, child_path, value[key])
    end
end

local function has_entry(entries, path)
    for _, item in ipairs(entries) do
        if item.path == path then
            return true
        end
    end
    return false
end

function M.schema()
    local entries = {}
    flatten(entries, "", config.defaults())

    for _, path in ipairs(optional_nil_defaults) do
        if not has_entry(entries, path) then
            entries[#entries + 1] = {
                path = path,
                type = optional_types[path] or "nil|string",
                default = "nil",
            }
        end
    end

    table.sort(entries, function(left, right)
        return left.path < right.path
    end)
    return entries
end

local function markdown_escape(value)
    return tostring(value):gsub("|", "\\|")
end

function M.markdown()
    local lines = {
        "# typst.nvim Config Reference",
        "",
        "This file is generated from the runtime defaults. Run `just config-docs` after changing `lua/typst/config/defaults.lua`, `lua/typst/config/default_editor.lua`, or `lua/typst/config/default_tools.lua`.",
        "",
        "<!-- typst.nvim config-reference:start -->",
        "| Key | Type | Default |",
        "| --- | --- | --- |",
    }

    for _, item in ipairs(M.schema()) do
        lines[#lines + 1] = ("| `%s` | `%s` | `%s` |"):format(
            markdown_escape(item.path),
            markdown_escape(item.type),
            markdown_escape(item.default)
        )
    end

    lines[#lines + 1] = "<!-- typst.nvim config-reference:end -->"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function json_string(value)
    return vim.json.encode(tostring(value))
end

function M.schema_json()
    local lines = {
        "{",
        '  "generated_by": "typst.config.docs",',
        '  "entries": [',
    }
    local entries = M.schema()
    for index, item in ipairs(entries) do
        local suffix = index == #entries and "" or ","
        lines[#lines + 1] = ('    { "path": %s, "type": %s, "default": %s }%s'):format(
            json_string(item.path),
            json_string(item.type),
            json_string(item.default),
            suffix
        )
    end
    lines[#lines + 1] = "  ]"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

return M
