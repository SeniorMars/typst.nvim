local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("render-cache-key-output"),
    render = {
        output_dir = typst_test_cache_path("render-cache-key-render"),
    },
})

local render = require("typst.workflows.render")

local project = {
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
}

local left = render._cache_key_for_tests(project, "fragment", {
    document_signature = "doc",
    format = "svg",
    source = "$x$",
    extra_args = {
        "--features",
        {
            zeta = true,
            alpha = {
                beta = 2,
                gamma = 3,
            },
        },
    },
})
local right = render._cache_key_for_tests(project, "fragment", {
    source = "$x$",
    format = "svg",
    document_signature = "doc",
    extra_args = {
        "--features",
        {
            alpha = {
                gamma = 3,
                beta = 2,
            },
            zeta = true,
        },
    },
})
assert(
    left == right,
    "render cache keys should be stable for reordered nested option tables"
)

local changed = render._cache_key_for_tests(project, "fragment", {
    document_signature = "doc",
    format = "svg",
    source = "$x$",
    extra_args = {
        "--features",
        {
            alpha = {
                beta = 2,
                gamma = 4,
            },
            zeta = true,
        },
    },
})
assert(
    changed ~= left,
    "render cache keys should still change when nested option values change"
)

vim.cmd("qa!")
