local M = {}

function M.setup(output_dir)
    local root = vim.fn.getcwd()
    vim.opt.runtimepath:prepend(root)

    local typst = require("typst")
    typst.reset()
    typst.setup({
        root = root,
        output_dir = output_dir or typst_test_cache_path("api-contract-output"),
    })

    return root, typst
end

return M
