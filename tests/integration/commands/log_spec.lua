local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("log-output"),
})
local notify_core = require("typst.core.notify")
local notifications = {}
assert(
    notify_core.result({ ok = true }, {
        notify = function(message, level)
            notifications[#notifications + 1] =
                { message = message, level = level }
        end,
        success = "done",
    }),
    "notify.result should emit a default success message"
)
assert(
    notifications[1]
        and notifications[1].message == "done"
        and notifications[1].level == vim.log.levels.INFO,
    "notify.result should default success notifications to info"
)
assert(
    notify_core.result({ ok = false, message = "failed" }, {
        notify = function(message, level)
            notifications[#notifications + 1] =
                { message = message, level = level }
        end,
    }),
    "notify.result should emit failure result messages"
)
assert(
    notifications[2]
        and notifications[2].message == "failed"
        and notifications[2].level == vim.log.levels.WARN,
    "notify.result should default failure notifications to warning"
)
assert(not notify_core.result({ ok = true, message = "quiet" }, {
    notify_false = true,
    notify = function()
        error("notify_false should suppress notifications")
    end,
}), "notify.result should honor notify_false")

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before log test")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish before log test"
)

local entries = typst.ui.log()
local saw_compile_started = false
for _, entry in ipairs(entries) do
    if entry.message == "compile started" then
        saw_compile_started = true
        assert(entry.fields.root == root, "compile log should include the root")
        assert(
            entry.fields.main == main,
            "compile log should include the main file"
        )
        assert(
            entry.fields.output == typst_test_compiler(project).output,
            "compile log should include the output path"
        )
        assert(entry.fields.cwd == root, "compile log should include the cwd")
        assert(
            vim.deep_equal(
                entry.fields.command,
                typst_test_compiler(project).last_command
            ),
            "compile log should include the command"
        )
    end
end

assert(saw_compile_started, "compile start should be present in typst.ui.log()")

vim.cmd("TypstLog")
local log_bufnr = vim.api.nvim_get_current_buf()
assert(
    vim.bo[log_bufnr].filetype == "typstlog",
    "TypstLog should open a typstlog buffer"
)
assert(
    vim.bo[log_bufnr].modifiable == false,
    "TypstLog buffer should not be modifiable"
)

local lines = vim.api.nvim_buf_get_lines(log_bufnr, 0, -1, false)
local text = table.concat(lines, "\n")
assert(
    text:find("compile started", 1, true),
    "TypstLog buffer should include compile start entry"
)
assert(
    text:find("command", 1, true),
    "TypstLog buffer should expose logged command fields"
)
assert(
    text:find(vim.pesc(typst_test_compiler(project).output)),
    "TypstLog buffer should expose logged output path"
)

local log = require("typst.core.log")
log.clear()
local empty_bufnr, empty_lines = log.open()
assert(
    vim.api.nvim_buf_is_valid(empty_bufnr),
    "log.open should return the opened buffer"
)
assert(
    #empty_lines == 1 and empty_lines[1] == "typst.nvim log is empty",
    "empty log should show a placeholder"
)

log.clear()
local large_chunk = ("x"):rep(5000)
log.add("debug", "large watcher chunk", {
    data = large_chunk,
    nested = {
        stdout = large_chunk,
    },
})
local large_entry = log.entries()[1]
assert(
    #large_entry.fields.data < #large_chunk,
    "log fields should truncate large string chunks"
)
assert(
    large_entry.fields.data:find("truncated", 1, true),
    "truncated log fields should be marked"
)
assert(
    #large_entry.fields.nested.stdout < #large_chunk,
    "nested log fields should also be truncated"
)

vim.cmd("qa!")
