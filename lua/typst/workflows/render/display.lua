local config = require("typst.config")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local render_cache = require("typst.workflows.render.cache")
local reports = require("typst.ui.reports")

local M = {}

local uv = vim.uv or vim.loop

local base64_alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local notify_user = require("typst.core.notify").user

local function render_config(opts)
    opts = opts or {}
    return vim.tbl_extend("force", config.unsafe_get().render or {}, opts or {})
end

local function display_provider(opts)
    return providers.resolve(
        "render",
        opts.display_provider or render_config(opts).display_provider
    )
end

local function base64_encode(data)
    local out = {}
    local index = 1
    while index <= #data do
        local a = data:byte(index) or 0
        local b = data:byte(index + 1) or 0
        local c = data:byte(index + 2) or 0
        local triple = a * 65536 + b * 256 + c
        local pad = index + 1 > #data and 2 or (index + 2 > #data and 1 or 0)
        out[#out + 1] = base64_alphabet:sub(
            math.floor(triple / 262144) % 64 + 1,
            math.floor(triple / 262144) % 64 + 1
        )
        out[#out + 1] = base64_alphabet:sub(
            math.floor(triple / 4096) % 64 + 1,
            math.floor(triple / 4096) % 64 + 1
        )
        out[#out + 1] = pad >= 2 and "="
            or base64_alphabet:sub(
                math.floor(triple / 64) % 64 + 1,
                math.floor(triple / 64) % 64 + 1
            )
        out[#out + 1] = pad >= 1 and "="
            or base64_alphabet:sub(triple % 64 + 1, triple % 64 + 1)
        index = index + 3
    end
    return table.concat(out)
end

local function read_binary_file(path)
    local ok, stat = pcall(uv.fs_stat, path)
    if not ok or not stat or stat.type ~= "file" then
        return nil
    end
    if stat.size == 0 then
        return ""
    end

    local fd, open_err = uv.fs_open(path, "r", 438)
    if not fd then
        return nil, open_err
    end

    local data, read_err = uv.fs_read(fd, stat.size, 0)
    pcall(uv.fs_close, fd)
    if type(data) ~= "string" then
        return nil, read_err
    end
    return data
end

local function base64_file(path)
    local data = read_binary_file(path)
    if not data then
        return nil
    end
    return base64_encode(data)
end

local function detected_terminal_provider()
    if vim.env.KITTY_WINDOW_ID then
        return "kitty"
    end
    if vim.env.WEZTERM_PANE then
        return "wezterm"
    end
    if vim.env.TERM_PROGRAM == "iTerm.app" then
        return "iterm"
    end
end

local function terminal_provider_name(provider)
    if provider == "terminal" or provider == "auto" then
        return detected_terminal_provider()
    end
    if provider == "kitty" or provider == "iterm" or provider == "wezterm" then
        return provider
    end
end

local function kitty_sequence(path)
    return "\27_Ga=T,t=f;" .. base64_encode(path) .. "\27\\"
end

local function iterm_sequence(path, opts)
    local limit = render_config(opts).max_inline_image_bytes
    local size = render_cache.file_size(path)
    if type(limit) == "number" and limit > 0 and size > limit then
        return nil,
            ("image is too large for inline terminal display (%d bytes > %d bytes)"):format(
                size,
                limit
            )
    end

    local encoded = base64_file(path)
    if not encoded then
        return nil, "failed to read image bytes for inline terminal display"
    end
    local name = vim.fn.fnamemodify(path, ":t")
    return "\27]1337;File=inline=1;preserveAspectRatio=1;name="
        .. base64_encode(name)
        .. ":"
        .. encoded
        .. "\7"
end

local function terminal_sequence(kind, path, opts)
    if kind == "kitty" then
        return kitty_sequence(path)
    end
    if kind == "iterm" or kind == "wezterm" then
        return iterm_sequence(path, opts)
    end
end

local function open_terminal_display(result, kind, opts)
    local sequence, err = terminal_sequence(kind, result.path, opts)
    if not sequence then
        return nil, err
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "typstrender"
    pcall(
        vim.api.nvim_buf_set_name,
        buf,
        ("typst.nvim %s preview %s"):format(kind, result.path)
    )
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    local chan = vim.api.nvim_open_term(buf, {})
    vim.api.nvim_chan_send(chan, sequence .. "\r\n" .. result.path .. "\r\n")
    return {
        provider = kind,
        buffer = buf,
        channel = chan,
        path = result.path,
    }
end

function M.image_dimensions(path, format)
    if format == "svg" then
        local ok, lines = pcall(vim.fn.readfile, path, "", 20)
        if ok then
            local text = table.concat(lines, "\n")
            local width = text:match('width="([^"]+)"')
            local height = text:match('height="([^"]+)"')
            local viewbox = text:match('viewBox="([^"]+)"')
                or text:match('viewbox="([^"]+)"')
            if width or height or viewbox then
                return {
                    width = width,
                    height = height,
                    viewbox = viewbox,
                }
            end
        end
    end
end

local function scratch_lines(result)
    local lines = {
        "typst.nvim rendered preview",
        ("  kind: %s"):format(result.kind or "render"),
        ("  path: %s"):format(result.path or ""),
        ("  format: %s"):format(result.format or ""),
        ("  cached: %s"):format(result.cached and "yes" or "no"),
    }
    if result.source_path then
        lines[#lines + 1] = ("  source: %s"):format(result.source_path)
    end
    if result.page then
        lines[#lines + 1] = ("  page: %s"):format(result.page)
    end
    if result.dimensions then
        if result.dimensions.width or result.dimensions.height then
            lines[#lines + 1] = ("  size: %s x %s"):format(
                result.dimensions.width or "?",
                result.dimensions.height or "?"
            )
        end
        if result.dimensions.viewbox then
            lines[#lines + 1] = ("  viewBox: %s"):format(
                result.dimensions.viewbox
            )
        end
    end
    if result.message then
        lines[#lines + 1] = ("  message: %s"):format(result.message)
    end
    return lines
end

function M.display(result, opts, notify)
    opts = opts or {}
    local cfg = render_config(opts)
    if opts.open == false or cfg.open == false then
        return result
    end

    local provider = display_provider(opts)
    if
        type(provider) == "function"
        or (type(provider) == "table" and type(provider.display) == "function")
    then
        local value =
            provider_adapter.invoke(provider, "display", result, opts, {
                kind = "render-display",
                provider_name = type(provider) == "table" and provider.name
                    or "custom",
                async = false,
                allow_nil_result = true,
                args = { result, opts },
                callback_position = 3,
                normalize = function(raw)
                    return raw == nil and true or raw
                end,
            })
        if type(value) == "table" and value.ok == false then
            result.display_error = value.message or value.error or value.reason
        else
            result.display = value
            return result
        end
    elseif type(provider) == "string" then
        local terminal = terminal_provider_name(provider)
        if terminal then
            local value, err = open_terminal_display(result, terminal, opts)
            if value then
                result.display = value
                return result
            end
            result.display_error = err
        end
    end

    result.buffer = reports.open_scratch_buffer(
        "typst.nvim rendered preview",
        "typstrender",
        scratch_lines(result)
    )
    notify_user(
        notify,
        ("Rendered Typst %s preview"):format(result.kind or "source")
    )
    return result
end

return M
