local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_model = require("typst.project.model")

local function scratch_buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "= Scratch" })
    return bufnr
end

local function assert_scratch_path(path, bufnr)
    assert(
        path:match("typst%.nvim[/\\]unsaved[/\\][^/\\]+[/\\]buffer%-") ~= nil,
        ("scratch path should live under an unsaved session directory: %s"):format(
            path
        )
    )
    assert(
        path:match(("buffer%%-%d%%-%%d+%%.typ$"):format(bufnr)),
        ("scratch path should include buffer number and generated id: %s"):format(
            path
        )
    )
end

local first = scratch_buf()
local first_path = project_model.scratch_buffer_path(first)
local first_again = project_model.scratch_buffer_path(first)
assert(first_again == first_path, "scratch path should be stable per buffer")
pcall(vim.api.nvim_buf_del_var, first, "typst_scratch_id")
assert(
    project_model.scratch_buffer_path(first) == first_path,
    "stored scratch path should remain stable even if the generated id is missing"
)
assert_scratch_path(first_path, first)

vim.api.nvim_buf_delete(first, { force = true })
local second = scratch_buf()
local second_path = project_model.scratch_buffer_path(second)
assert_scratch_path(second_path, second)
assert(
    second_path ~= first_path,
    "new unnamed buffers should not reuse a previous scratch path"
)
if second == first then
    assert(
        second_path ~= first_path,
        "reused buffer numbers should still get distinct scratch paths"
    )
end

local simulated = scratch_buf()
local simulated_first = project_model.scratch_buffer_path(simulated)
pcall(vim.api.nvim_buf_del_var, simulated, "typst_scratch_id")
pcall(vim.api.nvim_buf_del_var, simulated, "typst_scratch_path")
local simulated_reuse = project_model.scratch_buffer_path(simulated)
assert(
    simulated_reuse ~= simulated_first,
    "a fresh buffer-local scratch id on the same buffer number should change the scratch path"
)

vim.cmd("qa!")
