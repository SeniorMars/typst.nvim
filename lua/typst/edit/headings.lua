local edit_repeat = require("typst.edit.repeat")
local cursor = require("typst.edit.cursor")
local ts = require("typst.core.treesitter")

local M = {}

local max_heading_level = 6

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function cursor_pos(bufnr, opts)
    return cursor.pos(bufnr, opts)
end

local function ok(result)
    result.ok = true
    return result
end

local function err(reason, message)
    return {
        ok = false,
        reason = reason,
        message = message,
    }
end

local function notify_result(result, opts)
    if opts and opts.notify == false then
        return
    end

    if result.ok then
        vim.notify(
            result.message or "Applied Typst transform",
            vim.log.levels.INFO,
            { title = "typst.nvim" }
        )
    else
        vim.notify(
            result.message or "Typst transform unavailable",
            vim.log.levels.WARN,
            { title = "typst.nvim" }
        )
    end
end

local function set_repeat(keys)
    edit_repeat.set(keys)
end

local function find_heading(bufnr, opts)
    opts = opts or {}
    return ts.find_containing(bufnr, "heading", cursor_pos(bufnr, opts))
end

local function find_heading_marker(bufnr, opts)
    local heading = find_heading(bufnr, opts)
    local row = nil
    if heading then
        row = ts.range(heading).start_row
    else
        local pos = cursor_pos(bufnr, opts)
        if not pos then
            return nil
        end
        row = pos[1]
    end

    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local indent, markers = line:match("^(%s*)(=+)%s+")
    if not markers then
        return nil
    end

    return {
        row = row,
        indent = indent,
        markers = markers,
    }
end

local function change_heading_level(direction, opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local marker = find_heading_marker(bufnr, opts)
    if not marker then
        local result = err("no_heading", "No surrounding Typst heading found")
        notify_result(result, opts)
        return result
    end

    local level = #marker.markers
    local action = direction < 0 and "promote_heading" or "demote_heading"
    if direction < 0 and level <= 1 then
        local result =
            err("min_heading_level", "Typst heading is already at level 1")
        notify_result(result, opts)
        return result
    end
    if direction > 0 and level >= max_heading_level then
        local result = err(
            "max_heading_level",
            ("Typst heading is already at level %d"):format(max_heading_level)
        )
        notify_result(result, opts)
        return result
    end

    local next_level = level + direction
    vim.api.nvim_buf_set_text(
        bufnr,
        marker.row,
        #marker.indent,
        marker.row,
        #marker.indent + level,
        {
            string.rep("=", next_level),
        }
    )

    local result = ok({
        action = action,
        message = ("%s Typst heading to level %d"):format(
            direction < 0 and "Promoted" or "Demoted",
            next_level
        ),
        level = next_level,
        start_row = marker.row,
    })
    set_repeat(
        direction < 0 and ":TypstPromoteHeading<CR>"
            or ":TypstDemoteHeading<CR>"
    )
    notify_result(result, opts)
    return result
end

function M.promote_heading(opts)
    return change_heading_level(-1, opts)
end

function M.demote_heading(opts)
    return change_heading_level(1, opts)
end

return M
