local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local typst = require("typst")
typst.reset()

local executable = helpers.fake_typst_sleep(root)

typst.setup({
    root = root,
    executable = executable,
    output_dir = typst_test_cache_path("info-process-output"),
    compile = {
        deps = false,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
local handle = typst.compiler.compile()

assert(
    typst_test_compiler(project).process == handle,
    "project should track active compile process before info"
)
local snapshot = typst.ui.status()
assert(
    snapshot.status == "compiling",
    "status() should expose active compile status"
)
assert(snapshot.process_pid, "status() should expose active compile pid")
assert(
    vim.deep_equal(snapshot.command, typst_test_compiler(project).last_command),
    "status() should expose active compile command"
)
assert(snapshot.cwd == root, "status() should expose active compile cwd")
assert(
    snapshot.root_source == "config.root",
    "status() should expose root decision source"
)
assert(
    snapshot.main_source == "buffer variable vim.b.typst_main",
    "status() should expose main decision source"
)

local captured = {}
local original_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks)
    for _, chunk in ipairs(chunks) do
        captured[#captured + 1] = chunk[1]
    end
end

local ok, err = pcall(function()
    typst.ui.info()
end)

vim.api.nvim_echo = original_echo
assert(ok, err)

local text = table.concat(captured, "\n")
assert(
    text:find("status:%s+compiling"),
    "TypstInfo should show active compile status"
)
assert(
    text:find("process pid:%s+%d+"),
    "TypstInfo should show active compile process pid"
)
assert(
    text:find("fake%-typst%-sleep%.py.* compile"),
    "TypstInfo should show active compile command"
)

typst.compiler.stop()

assert(
    vim.wait(10000, function()
        return typst_test_compiler(project).process == nil
            and handle:is_closing()
    end, 20),
    "active compile process did not stop after info test"
)

vim.cmd("qa!")
