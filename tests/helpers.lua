local M = {}

local function executable_command(candidates)
    for _, candidate in ipairs(candidates) do
        local executable = candidate[1]
        if vim.fn.executable(executable) == 1 then
            local command = vim.deepcopy(candidate)
            command[1] = vim.fn.exepath(executable)
            return command
        end
    end

    error("typst.nvim tests require python3, python, or py in PATH")
end

function M.python_command(script)
    local candidates
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        candidates = {
            { "python" },
            { "py", "-3" },
            { "python3" },
        }
    else
        candidates = {
            { "python3" },
            { "python" },
        }
    end

    local command = executable_command(candidates)
    command[#command + 1] = script
    return command
end

function M.fake_typst_sleep(root)
    return M.python_command(root .. "/tests/fixtures/fake-typst-sleep.py")
end

function M.fake_viewer(root)
    return M.python_command(root .. "/tests/fixtures/fake-viewer.py")
end

local function join(...)
    return vim.fs.joinpath(...)
end

function M.cache_path(...)
    if _G.typst_test_cache_path then
        return _G.typst_test_cache_path(...)
    end
    return join(vim.fn.stdpath("cache"), "typst.nvim", ...)
end

function M.state_path(...)
    if _G.typst_test_state_path then
        return _G.typst_test_state_path(...)
    end
    return join(vim.fn.stdpath("state"), "typst.nvim", ...)
end

function M.data_path(...)
    if _G.typst_test_data_path then
        return _G.typst_test_data_path(...)
    end
    return join(vim.fn.stdpath("data"), "typst.nvim", ...)
end

function M.config_path(...)
    if _G.typst_test_config_path then
        return _G.typst_test_config_path(...)
    end
    return join(vim.fn.stdpath("config"), "typst.nvim", ...)
end

function M.root_path(...)
    if _G.typst_test_root_path then
        return _G.typst_test_root_path(...)
    end

    local root = vim.env.TYPST_NVIM_TEST_ROOT or vim.env.TYPST_NVIM_TEST_XDG_ROOT
    if type(root) ~= "string" or root == "" then
        root = join(vim.fn.stdpath("cache"), "typst.nvim-test")
    end

    return join(root, ...)
end

return M
