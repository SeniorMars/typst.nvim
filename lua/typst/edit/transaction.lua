local M = {}

-- Counted edit helpers keep repeated transforms in one undo story where
-- possible. Stop as soon as an iteration fails or goes async so a count does
-- not keep applying after the buffer state has diverged from the first edit.

local function effective_count(opts)
    opts = opts or {}
    if opts.range and opts.range > 0 then
        return 1
    end
    local count = tonumber(opts.count)
    if not count or count < 1 then
        return 1
    end
    return math.floor(count)
end

function M.undojoin()
    pcall(function()
        vim.cmd("undojoin")
    end)
end

function M.counted(opts, apply)
    opts = opts or {}
    local count = effective_count(opts)
    if count == 1 then
        return apply(opts)
    end

    local base_opts = vim.deepcopy(opts)
    base_opts.count = nil
    local result = nil
    for index = 1, count do
        if index > 1 then
            M.undojoin()
        end

        local run_opts = vim.deepcopy(base_opts)
        if opts.notify ~= false and index < count then
            run_opts.notify = false
        end
        result = apply(run_opts)
        if type(result) == "table" and result.pending then
            result.count = index
            return result
        end
        if type(result) == "table" and result.ok == false then
            result.count = index - 1
            return result
        end
    end

    if type(result) == "table" then
        result.count = count
    end
    return result
end

function M.counted_current(apply)
    local count = vim.v.count1
    local result = nil
    for index = 1, count do
        if index > 1 then
            M.undojoin()
        end
        result = apply()
        if type(result) == "table" and result.pending then
            return result
        end
        if type(result) == "table" and result.ok == false then
            return result
        end
    end
    return result
end

return M
