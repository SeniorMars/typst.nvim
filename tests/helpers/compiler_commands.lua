local M = {}

function M.setup()
    local root = vim.fn.getcwd()
    vim.opt.runtimepath:prepend(root)

    local typst = require("typst")
    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("compiler-commands-output"),
        compile = {
            fragments = {
                output_dir = typst_test_cache_path(
                    "compiler-command-fragments"
                ),
            },
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local main_bufnr = vim.api.nvim_get_current_buf()
    local snapshot = typst.project.set_main(main)
    local project = require("typst.project.store").get(snapshot.key) or snapshot

    return {
        root = root,
        typst = typst,
        main = main,
        main_bufnr = main_bufnr,
        project = project,
    }
end

return M
