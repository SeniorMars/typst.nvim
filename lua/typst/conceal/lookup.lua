local config = require("typst.config")
local custom = require("typst.conceal.custom")
local metadata = require("typst.metadata")

local M = {}

local cache = nil

local function char(codepoint)
    return vim.fn.nr2char(codepoint, true)
end

local function alpha_map(upper_base, lower_base, exceptions)
    local map = {}
    exceptions = exceptions or {}
    for index = 0, 25 do
        local upper = string.char(("A"):byte() + index)
        local lower = string.char(("a"):byte() + index)
        map[upper] = exceptions[upper] or char(upper_base + index)
        map[lower] = exceptions[lower] or char(lower_base + index)
    end
    return map
end

local font_maps = {
    cal = alpha_map(0x1D49C, 0x1D4B6, {
        B = "ℬ",
        E = "ℰ",
        F = "ℱ",
        H = "ℋ",
        I = "ℐ",
        L = "ℒ",
        M = "ℳ",
        R = "ℛ",
        e = "ℯ",
        g = "ℊ",
        o = "ℴ",
    }),
    bb = alpha_map(0x1D538, 0x1D552, {
        C = "ℂ",
        H = "ℍ",
        N = "ℕ",
        P = "ℙ",
        Q = "ℚ",
        R = "ℝ",
        Z = "ℤ",
    }),
    frak = alpha_map(0x1D504, 0x1D51E, {
        C = "ℭ",
        H = "ℌ",
        I = "ℑ",
        R = "ℜ",
        Z = "ℨ",
    }),
    bold = alpha_map(0x1D400, 0x1D41A),
}

local superscripts = {
    ["0"] = "⁰",
    ["1"] = "¹",
    ["2"] = "²",
    ["3"] = "³",
    ["4"] = "⁴",
    ["5"] = "⁵",
    ["6"] = "⁶",
    ["7"] = "⁷",
    ["8"] = "⁸",
    ["9"] = "⁹",
    ["+"] = "⁺",
    ["-"] = "⁻",
    ["="] = "⁼",
    ["("] = "⁽",
    [")"] = "⁾",
    n = "ⁿ",
}

local subscripts = {
    ["0"] = "₀",
    ["1"] = "₁",
    ["2"] = "₂",
    ["3"] = "₃",
    ["4"] = "₄",
    ["5"] = "₅",
    ["6"] = "₆",
    ["7"] = "₇",
    ["8"] = "₈",
    ["9"] = "₉",
    ["+"] = "₊",
    ["-"] = "₋",
    ["="] = "₌",
    ["("] = "₍",
    [")"] = "₎",
}

local operators = {
    ["<="] = "≤",
    [">="] = "≥",
    ["->"] = "→",
    ["<-"] = "←",
    ["<->"] = "↔",
    ["=>"] = "⇒",
    ["!="] = "≠",
}

local wrappers = {
    abs = { open = "|", close = "|", title = "absolute value" },
    norm = { open = "‖", close = "‖", title = "norm" },
    floor = { open = "⌊", close = "⌋", title = "floor" },
    ceil = { open = "⌈", close = "⌉", title = "ceil" },
    sqrt = { open = "√", close = "", title = "square root" },
}

local accents = {
    hat = "\204\130",
    dot = "\204\135",
    tilde = "\204\131",
}

local function signature(opts, custom_math)
    local catalog = metadata.catalog()
    return table.concat({
        config.generation(),
        metadata.generation(),
        custom.generation(),
        catalog.version or "",
        catalog.requested_version or "",
        tostring(catalog.version_mismatch),
        tostring(opts.safety and opts.safety.max_display_width),
        tostring(opts.safety and opts.safety.allow_combining),
    }, "\0")
end

local function custom_record(name, replacement, provider)
    return {
        kind = "custom symbol",
        glyph = replacement,
        nvim_conceal_safe = true,
        name = name,
        canonical = name,
        symbol_id = ("custom.math.%s"):format(name),
        provider = provider,
    }
end

local function build(custom_math, opts)
    local catalog = metadata.catalog()
    local symbols = {}
    for name, record in pairs(catalog.symbols or {}) do
        symbols[name] = record
        if record.symbol_id then
            symbols[record.symbol_id] = record
        end
    end

    local emojis = {}
    for name, record in pairs(catalog.emojis or {}) do
        emojis[name] = record
        if record.symbol_id then
            emojis[record.symbol_id] = record
        end
    end

    local custom_symbols = {}
    for name, replacement in pairs(opts.custom and opts.custom.math or {}) do
        custom_symbols[name] =
            custom_record(name, replacement, "User conceal config")
    end
    for name, replacement in pairs(custom_math or {}) do
        custom_symbols[name] =
            custom_record(name, replacement, "User conceal registry")
    end

    return {
        signature = signature(opts, custom_math),
        catalog = catalog,
        symbols = symbols,
        custom_symbols = custom_symbols,
        emojis = emojis,
        scripts = {
            sup = superscripts,
            sub = subscripts,
        },
        fonts = font_maps,
        operators = operators,
        wrappers = wrappers,
        accents = accents,
    }
end

function M.current(custom_math, opts)
    opts = opts or config.unsafe_get().conceal
    local current_signature = signature(opts, custom_math)
    if cache and cache.signature == current_signature then
        return cache
    end

    cache = build(custom_math, opts)
    return cache
end

function M.reset()
    cache = nil
end

return M
