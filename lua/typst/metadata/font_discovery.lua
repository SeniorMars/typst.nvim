local config = require("typst.config")
local operation = require("typst.core.operation")
local scan_cache = require("typst.core.scan_cache")
local util = require("typst.core.util")

local M = {}

-- Font discovery merges configured names with `typst fonts`. The CLI result is
-- cached asynchronously so diagnostics never block editing on a slow Typst
-- executable or a missing font database.
local font_cache = {
    pending = false,
    job = nil,
    retry_at = nil,
}
local font_results = scan_cache.new()
local uv = vim.uv or vim.loop

function M.trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

local function command_key(command)
    return table.concat(util.command_prefix(command), "\0")
end

local function parse_font_output(stdout)
    local names = {}
    local seen = {}

    for line in (stdout or ""):gmatch("[^\r\n]+") do
        local name = M.trim(line)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    table.sort(names)
    return names
end

local function configured_font_names()
    local names = {}
    local seen = {}
    for _, name in ipairs(config.unsafe_get().completion.font_families or {}) do
        name = M.trim(name)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    return names
end

local function typst_font_names(timeout_ms)
    if timeout_ms == 0 then
        return {}
    end

    local executable = config.unsafe_get().executable
    if vim.fn.executable(util.command_executable(executable)) ~= 1 then
        return {}
    end

    local key = ("%s\0%d"):format(command_key(executable), timeout_ms)
    local cached = scan_cache.peek(font_results, key)
    if cached then
        return cached
    end
    if font_cache.pending == key then
        -- Return the last known answer while the CLI scan is in flight; font
        -- diagnostics are advisory and can update on the next request.
        return cached or {}
    end
    if font_cache.retry_at and font_cache.retry_at > uv.now() then
        return {}
    end

    local command = util.command_prefix(executable)
    command[#command + 1] = "fonts"

    font_cache.pending = key
    local job = operation.run("metadata-fonts", command, { text = true }, {
        timeout_ms = timeout_ms,
    })
    font_cache.job = job
    job:on_finish(function(result)
        if font_cache.job ~= job then
            return
        end
        local ok = result and result.code == 0
        if ok then
            scan_cache.put(font_results, key, parse_font_output(result.stdout))
        end
        font_cache = {
            pending = false,
            job = nil,
            retry_at = ok and nil or (uv.now() + math.max(timeout_ms, 1000)),
        }
    end)
    return {}
end

function M.available(opts)
    opts = opts or {}
    local timeout_ms = opts.timeout_ms
    if timeout_ms == nil then
        timeout_ms = config.unsafe_get().completion.font_scan_timeout_ms
    end

    local names = {}
    local seen = {}
    local function add(name)
        name = M.trim(name)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    for _, name in ipairs(configured_font_names()) do
        add(name)
    end
    for _, name in ipairs(typst_font_names(timeout_ms)) do
        add(name)
    end

    table.sort(names)
    return names
end

function M.reset()
    if font_cache.job then
        font_cache.job:cancel({ timeout_ms = 0, kill_timeout_ms = 0 })
    end
    font_cache = {
        pending = false,
        job = nil,
        retry_at = nil,
    }
    scan_cache.reset(font_results)
end

return M
