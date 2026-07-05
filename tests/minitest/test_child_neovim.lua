local MiniTest = require("mini.test")

local helpers = require("tests.minitest.helpers")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["loads typst.nvim in an isolated child"] = function()
    local child = helpers.start_child()

    child.lua([[
        local typst = require("typst")
        typst.reset()
        typst.setup({
            root = vim.fn.getcwd(),
            output_dir = typst_test_cache_path("minitest-child-output"),
        })
vim.cmd.edit("tests/fixtures/basic/main.typ")
        vim.bo.filetype = "typst"
        typst.project.set_main(vim.api.nvim_buf_get_name(0))
    ]])

    eq(child.lua_get("vim.g.typst_nvim_disable_tinymist_autostart"), 1)
    eq(child.lua_get("require('typst').ui.status(0).attached"), true)
    eq(
        child.lua_get(
            "vim.fn.fnamemodify(require('typst').ui.status(0).main, ':t')"
        ),
        "main.typ"
    )
end

T["starts each child with fresh project state"] = function()
    local child = helpers.start_child()

    eq(child.lua_get("vim.tbl_count(require('typst.project').all())"), 0)
end

return T
