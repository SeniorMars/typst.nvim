local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local process = require("typst.core.process")
local formatting = require("typst.formatting")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("format-async-output"),
    format = {
        provider = "command",
        command = vim.v.progpath,
    },
})

local original_spawn = process.spawn
local spawned = {}

local function flush_scheduled()
    vim.wait(20, function()
        return false
    end, 1, false)
end

process.spawn = function(command, opts, handlers)
    local handle = {
        command = command,
        opts = opts,
        handlers = handlers,
        closed = false,
    }

    function handle:is_closing()
        return self.closed
    end

    function handle:kill()
        self.closed = true
    end

    function handle:finish(result)
        self.closed = true
        handlers.on_exit(result)
    end

    spawned[#spawned + 1] = handle
    return handle
end

local ok, err = xpcall(function()
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local bufnr = vim.api.nvim_get_current_buf()
    typst.project.set_main(main)

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Original" })
    local changed_result = nil
    local generation_before = formatting._generation(bufnr)
    local pending = formatting.format({ notify = false }, function(result)
        changed_result = result
    end)

    assert(pending.pending, "format command should run asynchronously")
    assert(
        formatting._generation(bufnr) == generation_before + 1,
        "command formatting should increment apply generation once"
    )
    assert(
        spawned[1].opts.stdin == "Original\n",
        "formatter should receive the starting buffer text"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "User edit" })
    spawned[1]:finish({ code = 0, stdout = "Formatted\n", stderr = "" })
    flush_scheduled()

    assert(
        changed_result and changed_result.reason == "buffer_changed",
        "format completion should reject edited buffers"
    )
    assert(
        vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
            "User edit",
        }),
        "format completion should not overwrite user edits"
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Base" })
    local first_result = nil
    local second_result = nil
    formatting.format({ notify = false }, function(result)
        first_result = result
    end)
    formatting.format({ notify = false }, function(result)
        second_result = result
    end)

    local first = spawned[2]
    local second = spawned[3]
    second:finish({ code = 0, stdout = "Second\n", stderr = "" })
    flush_scheduled()
    first:finish({ code = 0, stdout = "First\n", stderr = "" })
    flush_scheduled()

    assert(
        second_result and second_result.ok and second_result.changed,
        "newer formatter result should apply"
    )
    assert(
        first_result and first_result.reason == "stale_format",
        "older formatter result should be stale"
    )
    assert(
        vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
            "Second",
        }),
        "older formatter result should not replace newer output"
    )
end, debug.traceback)

process.spawn = original_spawn

if not ok then
    error(err)
end

local formatexpr = require("typst.edit.formatexpr")

local prose = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(prose)
vim.bo[prose].filetype = "typst"
vim.bo[prose].textwidth = 34
vim.api.nvim_buf_set_lines(prose, 0, -1, false, {
    "This is a deliberately long prose line",
    "that should become a wrapped paragraph.",
})

assert(
    formatexpr.formatexpr(1, 2, prose) == 0,
    "prose formatexpr should handle plain paragraphs"
)
local prose_lines = vim.api.nvim_buf_get_lines(prose, 0, -1, false)
assert(#prose_lines > 2, "prose formatter should wrap long paragraphs")
assert(
    prose_lines[1]:find("deliberately", 1, true),
    "prose formatter should keep paragraph words"
)

local comments = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(comments)
vim.bo[comments].filetype = "typst"
vim.bo[comments].textwidth = 36
vim.api.nvim_buf_set_lines(comments, 0, -1, false, {
    "/// This is a deliberately long doc",
    "/// comment that should stay prefixed.",
})

assert(
    formatexpr.formatexpr(1, 2, comments) == 0,
    "comment formatexpr should handle line comments"
)
for _, line in ipairs(vim.api.nvim_buf_get_lines(comments, 0, -1, false)) do
    assert(
        line:match("^/// "),
        "comment formatter should preserve the comment prefix"
    )
end

local source = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(source)
vim.bo[source].filetype = "typst"
vim.bo[source].textwidth = 30
vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    "#let value = (alpha, beta, gamma)",
})

assert(
    formatexpr.formatexpr(1, 1, source) == 1,
    "formatexpr should decline source-like code"
)
assert(
    vim.api.nvim_buf_get_lines(source, 0, -1, false)[1]
        == "#let value = (alpha, beta, gamma)",
    "declined source formatting should leave source unchanged"
)

vim.cmd("qa!")
