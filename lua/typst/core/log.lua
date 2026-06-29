local M = {}

local entries = {}
local MAX_FIELD_STRING = 4096
local MAX_FIELD_DEPTH = 4
local MAX_FIELD_ITEMS = 50

local function truncate_string(value)
    if #value <= MAX_FIELD_STRING then
        return value
    end

    return value:sub(1, MAX_FIELD_STRING)
        .. (" ... [truncated %d bytes]"):format(#value - MAX_FIELD_STRING)
end

local function sanitize_fields(value, depth, seen)
    if type(value) == "string" then
        return truncate_string(value)
    end
    if type(value) ~= "table" then
        return value
    end
    if depth >= MAX_FIELD_DEPTH then
        return "<max depth>"
    end
    if seen[value] then
        return "<cycle>"
    end

    seen[value] = true
    local sanitized = {}
    local count = 0
    for key, field in pairs(value) do
        count = count + 1
        if count > MAX_FIELD_ITEMS then
            sanitized["<truncated>"] = true
            break
        end

        local sanitized_key = key
        if type(sanitized_key) == "string" then
            sanitized_key = truncate_string(sanitized_key)
        elseif type(sanitized_key) == "table" then
            sanitized_key = tostring(sanitized_key)
        end
        sanitized[sanitized_key] = sanitize_fields(field, depth + 1, seen)
    end
    seen[value] = nil
    return sanitized
end

local function trim(max_entries)
    while #entries > max_entries do
        table.remove(entries, 1)
    end
end

--- Add an entry to the in-memory typst.nvim log.
---@param level string Log level.
---@param message string Log message.
---@param fields? table Structured fields to sanitize and store.
function M.add(level, message, fields)
    local ok, config = pcall(require, "typst.config")
    local max_entries = ok and config.unsafe_get().log.max_entries or 200

    entries[#entries + 1] = {
        time = os.date("%H:%M:%S"),
        level = level,
        message = message,
        fields = sanitize_fields(fields or {}, 0, {}),
    }

    trim(max_entries)
end

--- Return a copy of all log entries.
---@return table[] entries Log entry snapshot.
function M.entries()
    return vim.deepcopy(entries)
end

--- Clear all log entries.
function M.clear()
    entries = {}
end

--- Format one log entry for display.
---@param entry table Log entry.
---@return string line Formatted log line.
function M.format(entry)
    local suffix = ""
    if entry.fields and next(entry.fields) ~= nil then
        suffix = " " .. vim.inspect(entry.fields):gsub("%s*\n%s*", " ")
    end

    return ("[%s] %-5s %s%s"):format(
        entry.time,
        entry.level:upper(),
        entry.message,
        suffix
    )
end

--- Return formatted log lines.
---@return string[] lines Formatted log entries.
function M.lines()
    return vim.tbl_map(M.format, entries)
end

--- Open the typst.nvim log in a scratch split.
---@return integer bufnr Scratch log buffer.
---@return string[] lines Lines written to the buffer.
function M.open()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "typstlog"
    local named = pcall(vim.api.nvim_buf_set_name, buf, "typst.nvim log")
    if not named then
        vim.api.nvim_buf_set_name(buf, ("typst.nvim log %d"):format(buf))
    end

    local lines = M.lines()
    if #lines == 0 then
        lines = { "typst.nvim log is empty" }
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)

    return buf, lines
end

return M
