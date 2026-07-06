local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local config = require("typst.config")
local telemetry = require("typst.core.telemetry")
local toc = require("typst.navigation.toc")
local toc_state = require("typst.navigation.toc_state")

config.setup({
    root = root,
    output_dir = typst_test_cache_path("toc-schedule-bounded-output"),
    toc = {
        follow_cursor = true,
        follow_delay_ms = 1,
    },
})

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(
    bufnr,
    typst_test_cache_path("toc-schedule-bounded", "main.typ")
)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "= Main" })
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_set_current_buf(bufnr)

local project = {
    key = "toc-schedule-bounded",
    root = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)),
    main = vim.api.nvim_buf_get_name(bufnr),
}

local old_is_open = toc.is_open
local old_follow = toc.follow
local follow_calls = 0
rawset(toc, "is_open", function(attached)
    return attached == project
end)
rawset(toc, "follow", function(attached, follow_bufnr)
    assert(attached == project, "TOC follow should keep project identity")
    assert(follow_bufnr == bufnr, "TOC follow should use latest buffer")
    follow_calls = follow_calls + 1
    return true
end)

local ok, err = xpcall(function()
    telemetry.reset()
    for _ = 1, 25 do
        assert(
            toc.schedule_follow(project, bufnr, { delay_ms = 1 }),
            "follow scheduling should accept an open TOC"
        )
    end
    assert(
        vim.wait(1000, function()
            return follow_calls == 1
        end, 5),
        ("TOC follow burst should coalesce to one callback, got %d"):format(
            follow_calls
        )
    )
    local metrics = telemetry.snapshot()
    assert(
        metrics["toc.follow.coalesced"]
            and metrics["toc.follow.coalesced"].count >= 24,
        "TOC follow burst should report coalesced schedules"
    )
    assert(
        metrics["toc.follow.execute"]
            and metrics["toc.follow.execute"].count == 1,
        "TOC follow burst should execute once"
    )
end, debug.traceback)

toc_state.close_window(toc_state.for_project(project))
rawset(toc, "is_open", old_is_open)
rawset(toc, "follow", old_follow)
if not ok then
    error(err)
end

vim.cmd("qa!")
