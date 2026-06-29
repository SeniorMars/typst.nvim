local config = require("typst.config")
local completion_items = require("typst.completion.items")
local operation = require("typst.core.operation")
local scan_cache = require("typst.core.scan_cache")
local util = require("typst.core.util")

local M = {}

local fallback_families = {
    "DejaVu Sans Mono",
    "Libertinus Serif",
    "New Computer Modern",
    "New Computer Modern Math",
    "PT Sans",
    "PT Serif",
}

local cache = {
    pending = false,
    job = nil,
    retry_at = nil,
}
local font_results = scan_cache.new()
local uv = vim.uv or vim.loop

local function parse_font_output(stdout)
    local names = {}
    local seen = {}

    for line in (stdout or ""):gmatch("[^\r\n]+") do
        local name = completion_items.trim(line)
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    table.sort(names)
    return names
end

local function typst_font_families(completion_config)
    if completion_config.font_scan_timeout_ms == 0 then
        return {}
    end

    local executable = config.unsafe_get().executable
    if vim.fn.executable(util.command_executable(executable)) ~= 1 then
        return {}
    end

    local key = ("%s\0%d"):format(
        completion_items.command_key(executable),
        completion_config.font_scan_timeout_ms
    )
    local cached = scan_cache.peek(font_results, key)
    if cached then
        return cached
    end
    if cache.pending == key then
        return cached or {}
    end
    if cache.retry_at and cache.retry_at > uv.now() then
        return {}
    end

    local command = util.command_prefix(executable)
    command[#command + 1] = "fonts"

    cache.pending = key
    local job = operation.run("font-completion", command, { text = true }, {
        timeout_ms = completion_config.font_scan_timeout_ms,
    })
    cache.job = job
    job:on_finish(function(result)
        if cache.job ~= job then
            return
        end
        local ok = result and result.code == 0
        if ok then
            scan_cache.put(font_results, key, parse_font_output(result.stdout))
        end
        cache = {
            pending = false,
            job = nil,
            retry_at = ok and nil or (uv.now() + math.max(
                completion_config.font_scan_timeout_ms,
                1000
            )),
        }
    end)

    return {}
end

local function item(word, provider)
    return {
        word = word,
        abbr = word,
        menu = "[Typst font]",
        kind = "v",
        info = completion_items.info({
            ("Font family: %s"):format(word),
            provider == "typst" and "Discovered by typst fonts" or nil,
            provider == "config" and "Configured font family" or nil,
            provider == "fallback" and "Bundled fallback font family" or nil,
        }),
        user_data = {
            typst = {
                kind = "font_family",
                provider = provider,
                semantic = false,
            },
        },
    }
end

function M.items(opts, base)
    local completion_config = config.unsafe_get().completion
    if
        opts.include_fonts == false
        or completion_config.include_fonts == false
    then
        return {}
    end

    local items = {}
    local seen = {}
    local function add(word, provider)
        completion_items.add_unique(items, seen, word, function(value)
            return item(value, provider)
        end, { base = base })
    end

    for _, family in ipairs(completion_config.font_families or {}) do
        add(family, "config")
    end

    local typst_families = typst_font_families(completion_config)
    for _, family in ipairs(typst_families) do
        add(family, "typst")
    end

    if #typst_families == 0 then
        for _, family in ipairs(fallback_families) do
            add(family, "fallback")
        end
    end

    table.sort(items, function(a, b)
        if a.menu == b.menu then
            return a.word < b.word
        end
        return a.menu < b.menu
    end)

    return items
end

function M.reset()
    if cache.job then
        cache.job:cancel({ timeout_ms = 0, kill_timeout_ms = 0 })
    end
    cache = {
        pending = false,
        job = nil,
        retry_at = nil,
    }
    scan_cache.reset(font_results)
end

return M
