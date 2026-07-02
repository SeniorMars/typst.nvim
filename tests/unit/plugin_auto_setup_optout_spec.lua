local script = [[
local typst = require("typst")
assert(
    not typst.is_setup(),
    "plugin auto-setup opt-out should leave runtime unconfigured"
)
assert(
    vim.fn.exists(":TypstInfo") == 0,
    "plugin auto-setup opt-out should not register commands"
)
typst.setup({
    root = vim.fn.getcwd(),
    output_dir = vim.fs.joinpath(
        vim.fn.stdpath("cache"),
        "typst.nvim",
        "plugin-auto-setup-optout"
    ),
})
assert(typst.is_setup(), "explicit setup should configure the runtime")
assert(
    vim.fn.exists(":TypstInfo") == 2,
    "explicit setup should register commands after plugin opt-out"
)
vim.cmd("qa!")
]]

local script_path = vim.fn.tempname() .. ".lua"
vim.fn.writefile(vim.split(script, "\n", { plain = true }), script_path)
local result = vim.system({
    vim.v.progpath,
    "--headless",
    "-n",
    "--cmd",
    "let g:typst_nvim_no_auto_setup = 1",
    "-u",
    "tests/minimal_init.lua",
    "-l",
    script_path,
}, { text = true }):wait()
vim.fn.delete(script_path)

assert(
    result.code == 0,
    ("plugin auto-setup opt-out child failed\nstdout:\n%s\nstderr:\n%s"):format(
        result.stdout or "",
        result.stderr or ""
    )
)
