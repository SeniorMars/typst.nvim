local completion_paths = require("typst.completion.paths")
local coordinates = require("typst.core.coordinates")
local position = require("typst.completion.position")
local ts = require("typst.core.treesitter")

local M = {}

local kind_cache = {}

---@class TypstCompletionContextCallbacks
---@field parameter_value? fun(bufnr: number, row: number, col: number): boolean
---@field parameter? fun(bufnr: number, row: number, col: number): boolean

local function changedtick(bufnr)
    local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, bufnr)
    return ok and tick or -1
end

local function callback_id(callback)
    return type(callback) == "function" and tostring(callback) or ""
end

local function bibliography_style_context(bufnr, row, col)
    local before = coordinates.line_before_cursor(bufnr, row, col)
    if
        not before:find("bibliography%s*%(", 1)
        and not before:find("cite%s*%(", 1)
    then
        return false
    end

    return before:match('style%s*:%s*"[%w_./%-]*$') ~= nil
        or before:match("style%s*:%s*[%w_./%-]*$") ~= nil
end

local function raw_language_context(bufnr, row, col)
    local before = coordinates.line_before_cursor(bufnr, row, col)
    return before:match("^%s*```[%w_+#.+-]*$") ~= nil
end

local color_fields = {
    background = true,
    fill = true,
    paint = true,
    stroke = true,
}

local function color_context(bufnr, row, col)
    local before = coordinates.line_before_cursor(bufnr, row, col)
    if before:match("color%.map%.[%w_.%-]*$") then
        return true
    end

    local field = before:match("([%w%-]+)%s*:%s*[%w_.%-]*$")
    if field and color_fields[field] then
        return true
    end

    field = before:match("([%w%-]+)%s*:%s*.-[%+%(,]%s*[%w_.%-]*$")
    return field and color_fields[field] or false
end

local function font_family_context(bufnr, row, col)
    local before = coordinates.line_before_cursor(bufnr, row, col)
    return before:match('font%s*:%s*"[^"]*$') ~= nil
        or before:match("font%s*:%s*[%w%s_.%-]*$") ~= nil
end

local function classify_kind(bufnr, row, col, callbacks)
    if bibliography_style_context(bufnr, row, col) then
        return "csl_style"
    end

    if raw_language_context(bufnr, row, col) then
        return "raw_language"
    end

    if completion_paths.context_info(bufnr, row, col) then
        return "path"
    end

    if color_context(bufnr, row, col) then
        return "color"
    end

    if font_family_context(bufnr, row, col) then
        return "font_family"
    end

    if
        callbacks.parameter_value and callbacks.parameter_value(bufnr, row, col)
    then
        return "parameter_value"
    end

    if callbacks.parameter and callbacks.parameter(bufnr, row, col) then
        return "parameter"
    end

    if ts.find_containing(bufnr, { "equation", "math" }, { row, col }) then
        return "math"
    end

    return "markup"
end

function M.kind(bufnr, pos, callbacks)
    callbacks = callbacks or {}
    local resolved = position.resolve({ pos = pos }, bufnr)
    if not resolved then
        return nil
    end
    bufnr = resolved.bufnr
    local row, col = resolved.row, resolved.col
    local tick = changedtick(bufnr)
    local parameter_value_id = callback_id(callbacks.parameter_value)
    local parameter_id = callback_id(callbacks.parameter)
    local cached = kind_cache[bufnr]
    if
        cached
        and cached.tick == tick
        and cached.row == row
        and cached.col == col
        and cached.parameter_value_id == parameter_value_id
        and cached.parameter_id == parameter_id
    then
        return cached.kind
    end

    local kind = classify_kind(bufnr, row, col, callbacks)
    kind_cache[bufnr] = {
        tick = tick,
        row = row,
        col = col,
        parameter_value_id = parameter_value_id,
        parameter_id = parameter_id,
        kind = kind,
    }
    return kind
end

function M.clear_cache(bufnr)
    if bufnr ~= nil then
        kind_cache[bufnr] = nil
        return
    end
    kind_cache = {}
end

local function font_family_start(line, col)
    local before = line:sub(1, col)
    local quoted = before:match('font%s*:%s*"()[^"]*$')
    if quoted then
        return quoted - 1
    end

    local unquoted = before:match("font%s*:%s*()[%w%s_.%-]*$")
    if unquoted then
        return unquoted - 1
    end
end

function M.start(line, col)
    local raw_language_start = line:sub(1, col):match("^%s*```()[%w_+#.+-]*$")
    if raw_language_start then
        return raw_language_start - 1
    end

    local path_context = completion_paths.context_from_before(line:sub(1, col))
    if path_context then
        return path_context.start_col
    end

    local package_import_start = line:sub(1, col):match('#import%s+"()@[^"]*$')
    if package_import_start then
        return package_import_start - 1
    end

    local font_start = font_family_start(line, col)
    if font_start then
        return font_start
    end

    local start_col = col
    while start_col > 0 do
        local char = line:sub(start_col, start_col)
        if not char:match("[%w_.%-]") then
            break
        end
        start_col = start_col - 1
    end

    return start_col
end

return M
