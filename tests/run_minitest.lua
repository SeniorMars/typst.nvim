local ok, minitest = pcall(require, "mini.test")
if not ok then
    vim.api.nvim_echo({
        {
            "mini.test is required for this runner. "
                .. "Set TYPST_NVIM_TEST_MINI to a mini.nvim checkout, "
                .. "or add mini.nvim to TYPST_NVIM_TEST_EXTRA_RTP.",
            "ErrorMsg",
        },
    }, true, {})
    vim.cmd("cquit")
end

local root = vim.fn.getcwd()

local function collect_files()
    local files = {}
    local explicit = vim.env.TYPST_NVIM_MINITEST_FILES
    if explicit and explicit ~= "" then
        for file in
            vim.gsplit(explicit, " ", { plain = true, trimempty = true })
        do
            files[#files + 1] = file
        end
    else
        files =
            vim.fn.globpath(root .. "/tests/minitest", "test_*.lua", true, true)
    end

    table.sort(files)
    return files
end

local files = collect_files()
if #files == 0 then
    vim.api.nvim_echo({
        { "No mini.test files found under tests/minitest", "ErrorMsg" },
    }, true, {})
    vim.cmd("cquit")
end

minitest.setup({
    collect = {
        find_files = function()
            return files
        end,
    },
    execute = {
        reporter = minitest.gen_reporter.stdout({
            group_depth = 2,
            quit_on_finish = true,
        }),
    },
    script_path = "",
})
minitest.run()
