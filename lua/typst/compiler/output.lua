local M = {}

local WATCH_OUTPUT_LIMIT = 64 * 1024
local WATCH_LINE_BUFFER_LIMIT = 64 * 1024

-- Keep only recent watch output. A long-running watch process can produce
-- unbounded logs, but diagnostics and status only need the current cycle tail.

--- Append stream data while keeping only the most recent bytes.
---@param value? string Existing buffered output.
---@param data string New output chunk.
---@param limit? integer Maximum retained bytes.
---@return string value Bounded output buffer.
function M.append_bounded(value, data, limit)
    limit = limit or WATCH_OUTPUT_LIMIT
    value = (value or "") .. data
    if #value <= limit then
        return value
    end

    return value:sub(#value - limit + 1)
end

--- Split a watch stream chunk into complete lines.
---@param watcher table Watcher state that owns per-stream line buffers.
---@param stream '"stdout"'|'"stderr"' Output stream receiving the chunk.
---@param data string Raw output chunk.
---@return string[] lines Complete lines extracted from the chunk.
function M.complete_lines(watcher, stream, data)
    watcher.line_buffers = watcher.line_buffers or {}
    local text = (watcher.line_buffers[stream] or "") .. data
    text = text:gsub("\r\n", "\n")
    local lines = {}
    local start = 1

    while true do
        local newline = text:find("\n", start, true)
        if not newline then
            break
        end

        lines[#lines + 1] = text:sub(start, newline - 1)
        start = newline + 1
    end

    -- Stream chunks are not line-aligned. Hold the trailing partial line so the
    -- watch parser sees complete status messages, then flush it on process exit.
    watcher.line_buffers[stream] =
        M.append_bounded(nil, text:sub(start), WATCH_LINE_BUFFER_LIMIT)
    return lines
end

--- Return and clear any partial watch-output lines left on process exit.
---@param watcher table Watcher state that owns per-stream line buffers.
---@return table[] lines Pending line records with `stream` and `text` fields.
function M.flush_lines(watcher)
    local lines = {}
    for _, stream in ipairs({ "stdout", "stderr" }) do
        local pending = watcher.line_buffers and watcher.line_buffers[stream]
        if pending and pending ~= "" then
            lines[#lines + 1] = { stream = stream, text = pending }
            watcher.line_buffers[stream] = ""
        end
    end
    return lines
end

return M
