local M = {}

local function toc_module()
    return require("typst.navigation.toc")
end

function M.follow_open(attached, bufnr)
    local toc = toc_module()
    if toc.is_open(attached) then
        toc.follow(attached, bufnr)
    end
end

function M.schedule_follow_open(attached, bufnr)
    toc_module().schedule_follow(attached, bufnr)
end

function M.schedule_refresh(attached)
    toc_module().schedule_refresh(attached)
end

return M
