local M = {}

local uv = vim.uv or vim.loop
local entries = {}
local file_state = {
    last_error = nil,
    last_path = nil,
    dropped = 0,
    truncated = 0,
}
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

local function timestamp()
    local seconds, usec
    if uv and type(uv.gettimeofday) == "function" then
        seconds, usec = uv.gettimeofday()
    else
        seconds, usec = os.time(), 0
    end
    local ms = math.floor((usec or 0) / 1000)
    return os.date("!%Y-%m-%dT%H:%M:%S", seconds) .. (".%03dZ"):format(ms)
end

local function default_file_path()
    return require("typst.core.xdg").state_dir("typst.nvim.log.jsonl")
end

local function set_file_error(path, err)
    file_state.last_path = path
    file_state.last_error = tostring(err)
    file_state.dropped = file_state.dropped + 1
end

local function json_encode(value)
    if vim.json and type(vim.json.encode) == "function" then
        return pcall(vim.json.encode, value)
    end
    return pcall(vim.fn.json_encode, value)
end

local function log_config()
    local ok, config = pcall(require, "typst.config")
    if not ok then
        return { max_entries = 200, file = false }
    end
    return config.unsafe_get().log or { max_entries = 200, file = false }
end

local function append_file(entry, cfg)
    if not (cfg and cfg.file == true) then
        return
    end

    local path = cfg.file_path
    if type(path) ~= "string" or path == "" then
        path = default_file_path()
    end

    local encoded_ok, encoded = json_encode(entry)
    if not encoded_ok then
        set_file_error(path, encoded)
        return
    end

    local max_bytes = tonumber(cfg.file_max_bytes) or 0
    if max_bytes > 0 and #encoded + 1 > max_bytes then
        local compact = {
            time = entry.time,
            timestamp = entry.timestamp,
            level = entry.level,
            message = "log entry exceeded file_max_bytes",
            fields = {
                original_bytes = #encoded,
                original_message = truncate_string(
                    tostring(entry.message or "")
                ),
                truncated = true,
            },
        }
        local compact_ok
        compact_ok, encoded = json_encode(compact)
        if not compact_ok then
            set_file_error(path, encoded)
            return
        end
        if #encoded + 1 > max_bytes then
            set_file_error(path, "encoded log entry exceeds file_max_bytes")
            return
        end
        file_state.truncated = file_state.truncated + 1
    end

    local stat = uv.fs_stat(path)
    if
        max_bytes > 0
        and stat
        and stat.size
        and stat.size + #encoded + 1 > max_bytes
    then
        local truncate_ok, truncate_result = pcall(vim.fn.writefile, {}, path)
        if not truncate_ok or truncate_result ~= 0 then
            set_file_error(path, truncate_result)
            return
        end
    end

    local parent = vim.fs.dirname(path)
    if parent and parent ~= "" then
        local mkdir_ok, mkdir_err = pcall(vim.fn.mkdir, parent, "p")
        if not mkdir_ok then
            set_file_error(path, mkdir_err)
            return
        end
    end
    local write_ok, write_result =
        pcall(vim.fn.writefile, { encoded }, path, "a")
    if not write_ok or write_result ~= 0 then
        set_file_error(path, write_result)
        return
    end
    file_state.last_path = path
    file_state.last_error = nil
end

--- Add an entry to the in-memory typst.nvim log.
---@param level string Log level.
---@param message string Log message.
---@param fields? table Structured fields to sanitize and store.
function M.add(level, message, fields)
    local cfg = log_config()
    local max_entries = cfg.max_entries or 200
    local entry = {
        time = os.date("%H:%M:%S"),
        timestamp = timestamp(),
        level = level,
        message = message,
        fields = sanitize_fields(fields or {}, 0, {}),
    }
    entries[#entries + 1] = entry

    trim(max_entries)
    append_file(entry, cfg)
end

--- Return a copy of all log entries.
---@return table[] entries Log entry snapshot.
function M.entries()
    return vim.deepcopy(entries)
end

--- Return the current file-sink health state.
---@return table state File logging state.
function M.file_state()
    return vim.deepcopy(file_state)
end

--- Clear all log entries.
function M.clear()
    entries = {}
    file_state.last_error = nil
    file_state.last_path = nil
    file_state.dropped = 0
    file_state.truncated = 0
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
