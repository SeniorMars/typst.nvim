local buffer_util = require("typst.core.buffer")

local M = {}

local function explicit_window(opts)
    opts = opts or {}
    return opts.open_winid or opts.jump_winid or opts.target_winid
end

local function destination_window(opts)
    local winid = explicit_window(opts)
    if winid ~= nil then
        winid = tonumber(winid)
        if not winid or not vim.api.nvim_win_is_valid(winid) then
            return nil, "invalid destination window"
        end
        return winid
    end

    return vim.api.nvim_get_current_win()
end

local function with_destination_window(opts, callback)
    local winid, err = destination_window(opts)
    if not winid then
        return nil, err
    end

    local ok, result = pcall(vim.api.nvim_win_call, winid, callback)
    if not ok then
        return nil, result
    end

    pcall(vim.api.nvim_set_current_win, winid)
    return result, nil, winid
end

--- Resolve the Neovim window that should receive opened file targets.
---
--- `bufnr` and `winid` are used elsewhere to resolve the source context under
--- a cursor. File-opening actions intentionally use a separate destination
--- option so programmatic callers do not accidentally conflate source and
--- target windows.
---@param opts? table Options with optional `open_winid`, `jump_winid`, or `target_winid`.
---@return integer? winid Destination window, defaulting to the current window.
---@return string? error Failure reason for an explicit invalid destination.
function M.destination_window(opts)
    return destination_window(opts)
end

local function executable(command)
    return vim.fn.executable(command) == 1
end

function M.ui_open(target)
    if not (vim.ui and type(vim.ui.open) == "function") then
        return nil, "vim.ui.open is unavailable"
    end

    local called, object, err = pcall(vim.ui.open, target)
    if called and object then
        return object
    end
    if not called then
        return nil, object
    end

    return nil, err or "vim.ui.open did not open target"
end

--- Show an existing buffer in the destination window.
---@param bufnr integer Buffer to display.
---@param opts? table Open options; `open_winid` selects the destination window.
---@return table? result Structured open result.
---@return string? error Failure reason.
function M.buffer(bufnr, opts)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return nil, "invalid buffer"
    end

    local result, err, winid = with_destination_window(opts, function()
        vim.api.nvim_set_current_buf(bufnr)
        return {
            ok = true,
            bufnr = bufnr,
        }
    end)
    if not result then
        return nil, err
    end
    result.winid = winid
    return result
end

--- Open a file path in the destination window, reusing a loaded buffer when possible.
---@param path string Path to edit.
---@param opts? table Open options; `open_winid` selects the destination window.
---@return table? result Structured open result.
---@return string? error Failure reason.
function M.file(path, opts)
    if type(path) ~= "string" or path == "" then
        return nil, "missing path"
    end

    local result, err, winid = with_destination_window(opts, function()
        local bufnr = buffer_util.edit_existing_or_path(path)
        if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
            return nil
        end
        return {
            ok = true,
            path = path,
            bufnr = bufnr,
        }
    end)
    if not result then
        return nil, err or "failed to open path"
    end
    result.winid = winid
    return result
end

--- Set a destination-window cursor using one-based line and column inputs.
---@param winid integer Destination window.
---@param bufnr integer Buffer displayed in the destination window.
---@param line integer One-based target line.
---@param column? integer One-based target column; nil defaults to the first column.
---@return table? result Normalized cursor result.
---@return string? error Failure reason.
function M.cursor(winid, bufnr, line, column)
    if
        not winid
        or not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr
    then
        return nil, "destination window does not display target buffer"
    end

    local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
    local target_line = math.min(math.max(tonumber(line) or 1, 1), line_count)
    local text = vim.api.nvim_buf_get_lines(
        bufnr,
        target_line - 1,
        target_line,
        false
    )[1] or ""
    local target_col = math.min(math.max((tonumber(column) or 1) - 1, 0), #text)
    vim.api.nvim_win_set_cursor(winid, { target_line, target_col })
    return {
        ok = true,
        line = target_line,
        column = target_col + 1,
    }
end

--- Open a file and optionally jump to a one-based line/column in that file.
---@param path string Path to edit.
---@param line? integer One-based target line.
---@param column? integer One-based target column.
---@param opts? table Open options; `open_winid` selects the destination window.
---@return table? result Structured open/jump result.
---@return string? error Failure reason.
function M.file_at(path, line, column, opts)
    local opened, err = M.file(path, opts)
    if not opened then
        return nil, err
    end

    if line ~= nil then
        local cursor, cursor_err =
            M.cursor(opened.winid, opened.bufnr, line, column)
        if not cursor then
            return nil, cursor_err
        end
        opened.line = cursor.line
        opened.column = cursor.column
    end

    return opened
end

local function platform_url_commands(url)
    if vim.fn.has("macunix") == 1 then
        return {
            { "open", url },
        }
    end
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        return {
            { "rundll32", "url.dll,FileProtocolHandler", url },
            { "explorer.exe", url },
        }
    end
    return {
        { "xdg-open", url },
        { "gio", "open", url },
        { "sensible-browser", url },
    }
end

local browser_aliases = {
    ["google-chrome"] = "chrome",
    ["chrome"] = "chrome",
    ["chromium"] = "chromium",
    ["chromium-browser"] = "chromium",
    ["firefox"] = "firefox",
    ["mozilla-firefox"] = "firefox",
    ["safari"] = "safari",
    ["edge"] = "edge",
    ["microsoft-edge"] = "edge",
    ["msedge"] = "edge",
    ["brave"] = "brave",
    ["brave-browser"] = "brave",
    ["opera"] = "opera",
    ["vivaldi"] = "vivaldi",
    ["arc"] = "arc",
}

local mac_browser_apps = {
    chrome = "Google Chrome",
    chromium = "Chromium",
    firefox = "Firefox",
    safari = "Safari",
    edge = "Microsoft Edge",
    brave = "Brave Browser",
    opera = "Opera",
    vivaldi = "Vivaldi",
    arc = "Arc",
}

local unix_browser_commands = {
    chrome = { "google-chrome", "chrome", "chromium-browser", "chromium" },
    chromium = { "chromium", "chromium-browser" },
    firefox = { "firefox" },
    edge = { "microsoft-edge", "msedge" },
    brave = { "brave-browser", "brave" },
    opera = { "opera" },
    vivaldi = { "vivaldi" },
}

local windows_browser_commands = {
    chrome = { "chrome", "chrome.exe" },
    chromium = { "chromium", "chromium.exe" },
    firefox = { "firefox", "firefox.exe" },
    edge = { "msedge", "msedge.exe" },
    brave = { "brave", "brave.exe" },
    opera = { "opera", "opera.exe" },
    vivaldi = { "vivaldi", "vivaldi.exe" },
}

local function browser_key(app)
    local lowered =
        tostring(app or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    return browser_aliases[lowered] or lowered
end

function M.url_commands(url)
    return platform_url_commands(url)
end

--- Return opener commands for an explicitly selected browser application.
---
--- `nil` and "default" intentionally return nil so callers can use the normal
--- OS URL opener path. Unknown names are treated as app names on macOS and as
--- executable names elsewhere.
---@param app? string Browser selector such as "firefox", "chrome", or "default".
---@param url string URL to open.
---@return string[][]? commands Candidate opener commands, or nil for default opener behavior.
function M.browser_commands(app, url)
    if app == nil or app == "" then
        return nil
    end

    local key = browser_key(app)
    if key == "default" or key == "system" or key == "os" then
        return nil
    end

    if vim.fn.has("macunix") == 1 then
        return {
            { "open", "-a", mac_browser_apps[key] or app, url },
        }
    end

    local candidates
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        candidates = windows_browser_commands[key] or { app }
    else
        candidates = unix_browser_commands[key] or { app }
    end

    local commands = {}
    for _, executable_name in ipairs(candidates) do
        commands[#commands + 1] = { executable_name, url }
    end
    return commands
end

function M.url_preflight(url, opts)
    opts = opts or {}
    if type(url) ~= "string" or url == "" then
        return {
            ok = false,
            reason = "missing_url",
            message = "missing URL",
            url = url,
        }
    end

    if opts.ui ~= false and vim.ui and type(vim.ui.open) == "function" then
        return {
            ok = true,
            provider = "vim.ui.open",
            url = url,
        }
    end

    local candidates = opts.commands or platform_url_commands(url)
    local missing = {}
    for _, command in ipairs(candidates) do
        if executable(command[1]) then
            return {
                ok = true,
                provider = command[1],
                command = command,
                candidates = candidates,
                url = url,
            }
        end
        missing[#missing + 1] = command[1]
    end

    return {
        ok = false,
        reason = "opener_unavailable",
        message = ("no URL opener executable is available: %s"):format(
            #missing > 0 and table.concat(missing, ", ") or "<none>"
        ),
        candidates = candidates,
        missing = missing,
        url = url,
    }
end

local function start_detached(command)
    if not executable(command[1]) then
        return nil, ("executable not found: %s"):format(command[1])
    end

    local ok, job = pcall(vim.fn.jobstart, command, { detach = true })
    if ok and type(job) == "number" and job > 0 then
        return job
    end
    return nil,
        ok and ("jobstart returned %s"):format(vim.inspect(job)) or tostring(
            job
        )
end

--- Open a URL using Neovim UI support or a platform-specific opener.
---@param url string URL to open.
---@param opts? table Options; `ui=false` skips vim.ui.open, `commands` overrides fallback commands.
---@return table? result Structured open result.
---@return string? error Failure reason when no opener succeeds.
function M.url(url, opts)
    opts = opts or {}
    if type(url) ~= "string" or url == "" then
        return nil, "missing URL"
    end

    if opts.ui ~= false then
        local object = M.ui_open(url)
        if object then
            return {
                ok = true,
                provider = "vim.ui.open",
                url = url,
                object = object,
            }
        end
    end

    local last_err = nil
    for _, command in ipairs(opts.commands or platform_url_commands(url)) do
        local job, err = start_detached(command)
        if job then
            return {
                ok = true,
                provider = command[1],
                command = command,
                job = job,
                url = url,
            }
        end
        last_err = err
    end

    return nil, last_err or "no URL opener is available"
end

return M
