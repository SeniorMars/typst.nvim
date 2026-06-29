local root = vim.fn.getcwd()

vim.opt.runtimepath:prepend(root)
vim.opt.packpath:prepend(root)

local function prepend_runtimepath(path)
    if type(path) ~= "string" or path == "" then
        return
    end
    vim.opt.runtimepath:prepend(path)
    vim.opt.packpath:prepend(path)
end

if vim.env.TYPST_NVIM_TEST_DEPS and vim.env.TYPST_NVIM_TEST_DEPS ~= "" then
    prepend_runtimepath(vim.env.TYPST_NVIM_TEST_DEPS)
end

if vim.env.TYPST_NVIM_TEST_MINI and vim.env.TYPST_NVIM_TEST_MINI ~= "" then
    prepend_runtimepath(vim.env.TYPST_NVIM_TEST_MINI)
end

if
    vim.env.TYPST_NVIM_TEST_EXTRA_RTP
    and vim.env.TYPST_NVIM_TEST_EXTRA_RTP ~= ""
then
    for path in
        vim.gsplit(
            vim.env.TYPST_NVIM_TEST_EXTRA_RTP,
            package.config:sub(1, 1) == "\\" and ";" or ":",
            { plain = true, trimempty = true }
        )
    do
        prepend_runtimepath(path)
    end
end

local function configure_typst_parser_source()
    local repo = vim.env.TYPST_NVIM_TEST_PARSER_REPO
        or "https://github.com/SeniorMars/tree-sitter-typst"
    local revision = vim.env.TYPST_NVIM_TEST_PARSER_REVISION
        or "e3785aaa8b832e03d3559d912cd09b0577537c64"
    local ok, parsers = pcall(require, "nvim-treesitter.parsers")
    if not ok or not parsers then
        return
    end

    local configs = parsers.get_parser_configs()
    configs.typst = vim.tbl_deep_extend("force", configs.typst or {}, {
        install_info = {
            url = repo,
            files = { "src/parser.c", "src/scanner.c" },
            branch = vim.env.TYPST_NVIM_TEST_PARSER_BRANCH or "main",
            revision = revision,
        },
        filetype = "typst",
    })
end

configure_typst_parser_source()

local parser_roots = {}
if vim.env.TYPST_NVIM_TEST_PARSER and vim.env.TYPST_NVIM_TEST_PARSER ~= "" then
    parser_roots[#parser_roots + 1] = vim.env.TYPST_NVIM_TEST_PARSER
end
for _, parser_root in ipairs(parser_roots) do
    if vim.fn.isdirectory(parser_root) == 1 then
        prepend_runtimepath(parser_root)
    end
end

vim.opt.shadafile = "NONE"

vim.g.typst_nvim_disable_tinymist_autostart = 1

local function join(...)
    return vim.fs.joinpath(...)
end

function _G.typst_test_cache_path(...)
    return join(vim.fn.stdpath("cache"), "typst.nvim", ...)
end

function _G.typst_test_state_path(...)
    return join(vim.fn.stdpath("state"), "typst.nvim", ...)
end

function _G.typst_test_data_path(...)
    return join(vim.fn.stdpath("data"), "typst.nvim", ...)
end

function _G.typst_test_config_path(...)
    return join(vim.fn.stdpath("config"), "typst.nvim", ...)
end

function _G.typst_test_root_path(...)
    local root = vim.env.TYPST_NVIM_TEST_XDG_ROOT
    if type(root) ~= "string" or root == "" then
        root = join(vim.fn.stdpath("cache"), "typst.nvim-test")
    end

    return join(root, ...)
end

function _G.typst_test_services(project)
    return require("typst.project.services").ensure(project) or {}
end

function _G.typst_test_compiler(project)
    return _G.typst_test_services(project).compiler or {}
end

function _G.typst_test_preview(project)
    return _G.typst_test_services(project).preview or {}
end

function _G.typst_test_artifacts(project)
    return _G.typst_test_services(project).artifacts or {}
end

function _G.typst_test_diagnostics(project)
    return _G.typst_test_services(project).diagnostics or {}
end
