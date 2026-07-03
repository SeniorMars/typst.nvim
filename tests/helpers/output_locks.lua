local outputs = require("typst.resources.outputs")

local M = {}

local uv = vim.uv or vim.loop

function M.base_dir(name)
    local dir = typst_test_cache_path(name or "output-locks")
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p")
    return dir
end

function M.lock_dir()
    local probe = vim.fs.joinpath(
        typst_test_cache_path("output-locks-probe"),
        "probe.pdf"
    )
    return vim.fn.fnamemodify(outputs._lock_path(probe), ":h")
end

function M.reset_lock_dir()
    local dir = M.lock_dir()
    vim.fn.delete(dir, "rf")
    vim.fn.mkdir(dir, "p")
end

function M.path(base, name)
    return vim.fs.joinpath(base, name)
end

function M.write_owner(path, owner)
    local lock_path = outputs._lock_path(path)
    vim.fn.mkdir(lock_path, "p")
    vim.fn.writefile({ vim.json.encode(owner) }, outputs._owner_path(path))
    return lock_path
end

function M.write_raw_owner(path, lines)
    local lock_path = outputs._lock_path(path)
    vim.fn.mkdir(lock_path, "p")
    vim.fn.writefile(lines or {}, outputs._owner_path(path))
    return lock_path
end

function M.age_owner(path, seconds)
    local owner_path = outputs._owner_path(path)
    local old_time = os.time() - seconds
    local ok, result, err = pcall(uv.fs_utime, owner_path, old_time, old_time)
    assert(
        ok and result ~= nil,
        "test fixture should be able to age an owner record"
            .. tostring(err and (": " .. err) or "")
    )
end

return M
