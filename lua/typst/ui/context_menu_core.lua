local open_helper = require("typst.core.open")
local position = require("typst.completion.position")
local util = require("typst.core.util")

local M = {}

---@class TypstContextAction
---@field id string
---@field title string
---@field kind string
---@field target table|nil
---@field context table|nil
---@field run fun(opts:table|nil):any

M.normalize_bufnr = require("typst.core.buffer").normalize_bufnr

function M.notify(message, level)
    require("typst.core.notify").default(message, level)
end

function M.add_action(actions, action)
    actions[#actions + 1] = action
end

local function target_text(target)
    if not target then
        return nil
    end

    return target.url
        or target.spec
        or target.path
        or target.name
        or target.word
end

function M.target_title(target)
    if not target then
        return "Open target"
    end

    local labels = {
        citation = "Open citation",
        definition = "Go to definition",
        label = "Go to label",
        package = "Open package",
        path = "Open file",
        url = "Open URL",
    }

    return labels[target.kind] or "Open target"
end

function M.current_context_pos(opts)
    local resolved = position.resolve(opts or {})
    if not resolved then
        return nil
    end
    return { resolved.row, resolved.col }
end

function M.transform_opts(bufnr, pos, run_opts)
    run_opts = run_opts or {}
    return vim.tbl_extend("force", run_opts, {
        bufnr = bufnr,
        pos = pos,
        notify = run_opts.notify == true,
    })
end

function M.line_at(bufnr, row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

function M.context_query(ctx)
    if not ctx then
        return nil
    end

    if ctx.kind == "package_member" and ctx.package and ctx.package.spec then
        return ctx.qualified_name or ctx.query
    end

    return ctx.query
end

function M.package_query(ctx, target)
    if ctx and ctx.kind == "package" then
        return ctx.query
    end

    if ctx and ctx.kind == "package_member" and ctx.package then
        return ctx.package.spec
    end

    if target and target.kind == "package" then
        return target.spec
    end
end

function M.copy_target(target)
    local value = target_text(target)
    if not value then
        return nil
    end

    vim.fn.setreg('"', value)
    M.notify(("Copied %s"):format(value))
    return value
end

function M.replace_range(bufnr, range, text)
    if not range or not text then
        return nil
    end

    vim.api.nvim_buf_set_text(
        bufnr,
        range.start_row,
        range.start_col,
        range.end_row,
        range.end_col,
        { text }
    )
    return text
end

function M.open_url(url, opts)
    if opts and opts.open == false then
        return url
    end

    local opened, err = open_helper.url(url)
    if opened then
        return url
    end

    vim.notify(
        ("Could not open URL: %s"):format(err),
        vim.log.levels.WARN,
        { title = "typst.nvim" }
    )
    return nil, err
end

function M.open_file_at(path, lnum, col, opts)
    if opts and opts.open == false then
        return path
    end

    local opened, err = open_helper.file(path, opts)
    if not opened then
        return nil, err
    end
    if lnum then
        local _, cursor_err =
            open_helper.cursor(opened.winid, opened.bufnr, lnum, col)
        if cursor_err then
            return nil, cursor_err
        end
    end

    return path
end

function M.reveal_file(path, opts)
    if not path or path == "" then
        return nil
    end

    local directory = util.dirname(path)
    local command
    if util.is_windows() then
        command = { "explorer.exe", "/select,", path }
    elseif vim.fn.has("macunix") == 1 then
        command = { "open", "-R", path }
    elseif directory and directory ~= "" then
        command = { "xdg-open", directory }
    end

    local info = {
        kind = "path",
        path = path,
        directory = directory,
        command = command,
    }

    if opts and opts.open == false then
        return info
    end

    if command and vim.fn.executable(command[1]) == 1 then
        vim.fn.jobstart(command, { detach = true })
    elseif directory and directory ~= "" and vim.ui and vim.ui.open then
        local object = open_helper.ui_open(directory)
        if not object then
            M.open_file_at(directory, nil, nil, opts or {})
        end
    elseif directory and directory ~= "" then
        M.open_file_at(directory, nil, nil, opts or {})
    end

    return info
end

return M
