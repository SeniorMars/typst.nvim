local M = {}

function M.winid()
    local ok, info = pcall(vim.fn.getqflist, { winid = 0 })
    if
        ok
        and type(info) == "table"
        and type(info.winid) == "number"
        and info.winid > 0
    then
        return info.winid
    end

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].buftype == "quickfix" then
            return winid
        end
    end
end

function M.is_toc()
    local ok, info = pcall(vim.fn.getqflist, { title = 1, winid = 0 })
    return ok
        and type(info) == "table"
        and type(info.title) == "string"
        and info.title:match("^typst%.nvim TOC:")
        and type(info.winid) == "number"
        and info.winid > 0
end

function M.matches_title(title)
    local ok, info = pcall(vim.fn.getqflist, { title = 1, winid = 0 })
    if not ok or type(info) ~= "table" or type(info.title) ~= "string" then
        return false
    end

    if title and info.title ~= title then
        return false
    end

    return type(info.winid) == "number" and info.winid > 0
end

function M.close_title(title)
    if not M.matches_title(title) then
        return false
    end

    vim.cmd("cclose")
    return true
end

function M.index()
    return math.max(vim.fn.line("."), 1)
end

function M.jump_to_item()
    vim.cmd(("cc %d"):format(M.index()))
end

function M.close()
    vim.cmd("cclose")
end

return M
