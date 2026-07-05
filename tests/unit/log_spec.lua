local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local log = require("typst.core.log")

local log_path = typst_test_state_path("log-spec", "typst.nvim.log.jsonl")
vim.fn.delete(vim.fs.dirname(log_path), "rf")

typst.reset()
typst.setup({
    root = root,
    log = {
        max_entries = 8,
        file = true,
        file_path = log_path,
        file_max_bytes = 4096,
    },
})
log.clear()
vim.fn.delete(log_path)
log.add("info", "jsonl sink test", {
    path = root,
    nested = {
        value = "ok",
    },
})
local entries = log.entries()
assert(entries[1], "log entry should be stored in memory")
assert(
    entries[1].timestamp
        and entries[1].timestamp:match("^%d%d%d%d%-%d%d%-%d%dT"),
    "log entries should include an ISO timestamp"
)

local lines = vim.fn.readfile(log_path)
assert(#lines == 1, "file sink should append one JSONL line")
local decoded = vim.json.decode(lines[1])
assert(decoded.message == "jsonl sink test", "file sink should encode message")
assert(decoded.fields.nested.value == "ok", "file sink should encode fields")
assert(
    decoded.timestamp and decoded.timestamp:match("Z$"),
    "file sink should include timestamp"
)

typst.setup({
    root = root,
    log = {
        max_entries = 8,
        file = true,
        file_path = log_path,
        file_max_bytes = 240,
    },
})
for index = 1, 5 do
    log.add("debug", "capped file sink", {
        index = index,
        payload = ("x"):rep(20),
    })
end
local stat = vim.uv.fs_stat(log_path)
assert(stat and stat.size <= 240, "file sink should enforce max byte cap")
local state = log.file_state()
assert(
    state.last_error == nil,
    "file sink should not report errors after small capped writes"
)

typst.setup({
    root = root,
    log = {
        max_entries = 8,
        file = true,
        file_path = log_path,
        file_max_bytes = 360,
    },
})
vim.fn.delete(log_path)
log.clear()
log.add("debug", "oversized file sink", {
    payload = ("x"):rep(8000),
})
stat = vim.uv.fs_stat(log_path)
assert(
    stat and stat.size <= 360,
    "single oversized log entries should not leave file above max byte cap"
)
lines = vim.fn.readfile(log_path)
decoded = vim.json.decode(lines[1])
assert(
    decoded.message == "log entry exceeded file_max_bytes",
    "oversized file entries should be compacted before writing"
)
state = log.file_state()
assert(
    state.truncated >= 1,
    "file sink should track compacted oversized entries"
)

typst.setup({
    root = root,
    log = {
        max_entries = 8,
        file = true,
        file_path = log_path,
        file_max_bytes = 20,
    },
})
vim.fn.delete(log_path)
log.clear()
log.add("debug", "too small cap", {
    payload = ("x"):rep(8000),
})
state = log.file_state()
assert(
    state.last_error ~= nil and state.dropped >= 1,
    "file sink should expose errors when even compact entries exceed the cap"
)

typst.reset({ force = true })
vim.cmd("qa!")
