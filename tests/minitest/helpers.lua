local M = {}

local MiniTest = require("mini.test")

local root = vim.fn.getcwd()
local minimal_init = root .. "/tests/minimal_init.lua"
local nvim_executable = vim.fn.exepath("nvim")
if nvim_executable == "" then
    nvim_executable = vim.v.progpath
end

function M.start_child()
    local child = MiniTest.new_child_neovim()
    child.start({ "-u", minimal_init }, {
        connection_timeout = 10000,
        nvim_executable = nvim_executable,
    })
    MiniTest.finally(function()
        child.stop()
    end)
    return child
end

return M
