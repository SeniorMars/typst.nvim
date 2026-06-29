local M = {}

function M.command_prefix(command)
    if type(command) == "table" then
        return vim.deepcopy(command)
    end

    return { command }
end

function M.command_executable(command)
    if type(command) == "table" then
        return command[1]
    end

    return command
end

function M.command_display(command)
    if type(command) == "table" then
        return table.concat(command, " ")
    end

    return command
end

return M
