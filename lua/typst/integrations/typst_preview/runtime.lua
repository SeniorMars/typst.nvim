local log = require("typst.core.log")

local M = {}

M.own_command_definition = "Delegate to the configured Typst preview backend"
M.own_stop_command_definition = "Stop the configured Typst preview backend"
M.own_toggle_command_definition = "Toggle the configured Typst preview backend"
M.own_inverse_command_definition =
    "Jump from a Typst preview source map to source"

local own_command_definitions = {
    TypstPreview = M.own_command_definition,
    TypstPreviewInverse = M.own_inverse_command_definition,
    TypstPreviewStop = M.own_stop_command_definition,
    TypstPreviewToggle = M.own_toggle_command_definition,
}

local function command_exists(name)
    return vim.fn.exists(":" .. name) == 2
end

local function cwd_snapshot()
    return {
        scope = vim.fn.haslocaldir(),
        cwd = vim.fn.getcwd(),
        global = vim.fn.getcwd(-1, -1),
    }
end

local function set_cwd(scope, path)
    local command = scope == 1 and "lcd" or scope == 2 and "tcd" or "cd"
    vim.cmd(command .. " " .. vim.fn.fnameescape(path))
end

local function restore_cwd(snapshot)
    if snapshot.scope == 1 or snapshot.scope == 2 then
        set_cwd(snapshot.scope, snapshot.cwd)
    else
        set_cwd(0, snapshot.global)
    end
end

local function with_project_cwd(project, callback)
    -- typst-preview.nvim reads cwd from Neovim state. Preserve the user's
    -- local/tab/global cwd scope while temporarily running from the project root.
    local snapshot = cwd_snapshot()
    set_cwd(snapshot.scope, project.root)

    local ok, result = pcall(callback)
    local restore_ok, restore_err = pcall(restore_cwd, snapshot)
    if not restore_ok then
        log.add(
            "warn",
            "failed to restore current directory after preview delegation",
            {
                root = project.root,
                error = restore_err,
            }
        )
    end

    if not ok then
        error(result)
    end

    return result
end

--- Check whether typst-preview.nvim can be required.
---@return boolean available True when the plugin module is available.
---@return any error Error from `require`, when unavailable.
function M.available()
    return pcall(require, "typst-preview")
end

--- Check whether a preview command exists and is not a typst.nvim shim.
---@param name? string Preview command name.
---@return boolean available True when an external preview command is available.
function M.command_available(name)
    name = name or "TypstPreview"
    if not command_exists(name) then
        return false
    end

    -- Commands registered by typst.nvim itself are shims, not proof that
    -- typst-preview.nvim is installed. Exclude them to avoid recursive
    -- delegation back into our own command callbacks.
    local command = vim.api.nvim_get_commands({ builtin = false })[name]
    local own_definition = own_command_definitions[name]
    return not command
        or (
            command.definition ~= own_definition
            and command.desc ~= own_definition
        )
end

--- Run a preview command from the project's main buffer and root cwd.
---@param project table Project state whose main file should be current.
---@param command string Preview command to execute.
---@return string cwd Project root used for command execution.
function M.run_from_main(project, command)
    local main_bufnr = vim.fn.bufadd(project.main)
    if main_bufnr <= 0 then
        error(
            ("typst.nvim: failed to load preview main buffer: %s"):format(
                project.main
            )
        )
    end
    vim.fn.bufload(main_bufnr)
    -- typst-preview.nvim reads the current buffer and cwd. Execute its command
    -- from the resolved main file instead of assuming the user's current window
    -- is the compile root.
    vim.api.nvim_buf_call(main_bufnr, function()
        with_project_cwd(project, function()
            vim.cmd(command)
        end)
    end)
    return project.root
end

--- Run a preview command after temporarily moving to a source position.
---@param project table Project state whose root cwd should be active.
---@param command string Preview command to execute.
---@param position? table Source position with line and column.
---@return string cwd Project root used for command execution.
function M.run_at_position(project, command, position)
    local location = require("typst.integrations.typst_preview.location")
    local original = vim.api.nvim_win_get_cursor(0)
    local moved = false

    if position and position.line and position.column then
        local line_count = math.max(vim.api.nvim_buf_line_count(0), 1)
        local line = math.min(math.max(position.line, 1), line_count)
        local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
            or ""
        local column = location.clamp_byte_col(text, position.column - 1)
        vim.api.nvim_win_set_cursor(0, { line, column })
        moved = true
    end

    local ok, err = pcall(with_project_cwd, project, function()
        vim.cmd(command)
    end)

    if moved then
        pcall(vim.api.nvim_win_set_cursor, 0, original)
    end

    if not ok then
        error(err)
    end

    return project.root
end

return M
