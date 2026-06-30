local M = {}

local ansi_pattern = "\27%[[%d;?]*[ -/]*[@-~]"

-- Typst watch output has changed across releases and can also be wrapped by
-- providers. Typst CLI 0.15 has no stable structured watch-status flag, but
-- wrappers and future Typst versions can emit JSON-line events. Accept known
-- human formats plus structured JSON, and surface status-looking unknown lines
-- so parser drift is visible in logs/tests.
local profiles = {
    {
        version = "0.11-0.15-human",
        start = {
            "^%s*%[%d%d:%d%d:%d%d%]%s+compiling%s+%.%.%.%s*$",
            "^%s*compiling%s+%.%.%.%s*$",
            "^%s*typst%s+watch:%s+compiling%s+%.%.%.%s*$",
        },
        success = {
            "^%s*%[%d%d:%d%d:%d%d%]%s+compiled%s+successfully",
            "^%s*compiled%s+successfully",
            "^%s*successfully%s+compiled",
            "^%s*compilation%s+succeeded",
            "^%s*compiled%s+in%s+[%d%.]+%s*%a+",
        },
        error = {
            "^%s*%[%d%d:%d%d:%d%d%]%s+compiled%s+with%s+errors",
            "^%s*compiled%s+with%s+errors",
            "^%s*compilation%s+failed",
            "^%s*compile%s+failed",
        },
    },
}

local function clean(line)
    line = tostring(line or ""):gsub(ansi_pattern, "")
    return line:gsub("\r", "")
end

local function matches_any(line, patterns)
    for _, pattern in ipairs(patterns or {}) do
        if line:match(pattern) then
            return true
        end
    end
    return false
end

local function status_like(line)
    local lower = line:lower()
    return lower:find("compil", 1, true) ~= nil
        or lower:find("typst watch", 1, true) ~= nil
end

local function decode_json_line(line)
    if line:match("^%s*{") == nil then
        return nil
    end

    if not vim.json or type(vim.json.decode) ~= "function" then
        return nil
    end

    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == "table" then
        return decoded
    end
end

local function structured_text(event, keys)
    local parts = {}
    for _, key in ipairs(keys or { "event", "type", "kind", "status", "phase" }) do
        if type(event[key]) == "string" then
            parts[#parts + 1] = event[key]
        end
    end
    return table.concat(parts, " "):lower()
end

local function has_start(text)
    return text:find("start", 1, true)
        or text:find("begin", 1, true)
        or text:find("running", 1, true)
end

local function has_success(text)
    return text:find("success", 1, true)
        or text:find("succeed", 1, true)
        or text:find("ok", 1, true)
        or text:find("done", 1, true)
        or text:find("finish", 1, true)
end

local function has_error(text)
    return text:find("error", 1, true) or text:find("fail", 1, true)
end

local function parse_structured(line)
    local decoded = decode_json_line(line)
    if not decoded then
        return nil
    end

    local control_text =
        structured_text(decoded, { "event", "type", "kind", "phase" })
    local status_text = structured_text(decoded, { "status" })
    local text = vim.trim(control_text .. " " .. status_text)
    if text == "" then
        return {
            event = "unknown",
            profile = "structured-json",
            line = line,
            structured = decoded,
        }
    end

    local mentions_compile = text:find("compil", 1, true) ~= nil
        or text:find("watch", 1, true) ~= nil
    local has_explicit_lifecycle = control_text ~= ""
        and (
            has_start(control_text)
            or has_success(control_text)
            or has_error(control_text)
        )
    if not mentions_compile and not has_explicit_lifecycle then
        return {
            event = "unknown",
            profile = "structured-json",
            line = line,
            structured = decoded,
        }
    end

    if has_start(text) then
        return {
            event = "start",
            profile = "structured-json",
            line = line,
            structured = decoded,
        }
    end

    if has_success(text) then
        return {
            event = "success",
            profile = "structured-json",
            line = line,
            structured = decoded,
        }
    end

    if has_error(text) then
        return {
            event = "error",
            profile = "structured-json",
            line = line,
            structured = decoded,
        }
    end

    if mentions_compile then
        return {
            event = "unknown",
            profile = "structured-json",
            line = line,
            structured = decoded,
        }
    end
end

--- Parse one `typst watch` status line into a compile-cycle event.
---@param line string Raw output line from Typst.
---@param opts? table Parser options; `structured_only` rejects human status lines.
---@return table? event Parsed event payload, or nil for non-status output.
function M.parse(line, opts)
    opts = opts or {}
    line = clean(line)
    local lower = line:lower()

    local structured = parse_structured(line)
    if structured then
        return structured
    end

    if opts.structured_only then
        if status_like(line) then
            return {
                event = "unknown",
                profile = "structured-required",
                reason = "non_structured_status",
                line = line,
            }
        end
        return nil
    end

    for _, profile in ipairs(opts.profiles or profiles) do
        if matches_any(lower, profile.start) then
            return {
                event = "start",
                profile = profile.version,
                line = line,
            }
        end
        if matches_any(lower, profile.success) then
            return {
                event = "success",
                profile = profile.version,
                line = line,
            }
        end
        if matches_any(lower, profile.error) then
            return {
                event = "error",
                profile = profile.version,
                line = line,
            }
        end
    end

    if status_like(line) then
        return {
            event = "unknown",
            line = line,
        }
    end
end

--- Return known human-output parser profiles.
---@return table[] profiles Deep copy of supported parser profiles.
function M.profiles()
    return vim.deepcopy(profiles)
end

return M
