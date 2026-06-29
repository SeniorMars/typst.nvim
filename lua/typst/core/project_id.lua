local M = {}

function M.project_id(project)
    local key = project.key or project.main or project.root or tostring(project)
    local ok, hashed = pcall(vim.fn.sha256, key)
    if ok and type(hashed) == "string" and hashed ~= "" then
        return hashed:sub(1, 24)
    end
    return tostring(key):gsub("[^%w_%-]", "_"):sub(1, 48)
end

return M
