local M = {}

--- Return true when a value is a dense 1-indexed sequence table.
---@param value any Value to classify.
---@return boolean is_list True for tables that can be safely consumed with `ipairs`.
function M.is_list(value)
    if type(value) ~= "table" then
        return false
    end
    if vim.islist then
        return vim.islist(value)
    end

    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        count = count + 1
    end
    for index = 1, count do
        if value[index] == nil then
            return false
        end
    end
    return true
end

M.unpack = table.unpack or rawget(_G, "unpack")

return M
