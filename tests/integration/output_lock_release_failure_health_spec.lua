local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local lock_helper = require("tests.helpers.output_locks")
local outputs = require("typst.resources.outputs")
local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local function capture_health()
    local messages = {}
    local old_health = vim.health
    vim.health = {
        start = function(message)
            messages[#messages + 1] = { level = "start", message = message }
        end,
        ok = function(message)
            messages[#messages + 1] = { level = "ok", message = message }
        end,
        warn = function(message)
            messages[#messages + 1] = { level = "warn", message = message }
        end,
        error = function(message)
            messages[#messages + 1] = { level = "error", message = message }
        end,
    }

    local ok, err = xpcall(function()
        require("typst.health").check()
    end, debug.traceback)
    vim.health = old_health
    assert(ok, err)
    return messages
end

cleanup()
outputs.reset()
lock_helper.reset_lock_dir()

local fixture_root = lock_helper.base_dir("output-lock-health")
local main = lock_helper.path(fixture_root, "main.typ")
vim.fn.mkdir(vim.fn.fnamemodify(main, ":h"), "p")
vim.fn.writefile({ "= Main" }, main)

typst.setup({
    root = fixture_root,
    completion = {
        package_cache_prewarm = false,
    },
})
vim.cmd.edit(main)
vim.bo.filetype = "typst"
local project = assert(typst.project.attach(0))

local output = lock_helper.path(fixture_root, "release-failure.pdf")
local lease = assert(outputs.acquire(output, outputs.owner("health", project)))
vim.fn.writefile({
    vim.json.encode({
        pid = 999999999,
        path = output,
        owner = { kind = "foreign-owner" },
    }),
}, outputs._owner_path(output))

assert(
    outputs.release(lease),
    "release should drop the in-process lease even if lock cleanup fails"
)

local messages = capture_health()
local saw_failure = false
local saw_hint = false
for _, item in ipairs(messages) do
    if
        item.level == "warn"
        and item.message:find(
            "Last output lock release failure: foreign_lock_owner",
            1,
            true
        )
    then
        saw_failure = true
        saw_hint = item.message:find(":TypstLocks", 1, true) ~= nil
            and item.message:find(":TypstCleanLocks!", 1, true) ~= nil
    end
end

assert(
    saw_failure,
    "health should retain global output lock release failures after release"
)
assert(saw_hint, "health should include output lock recovery commands")

vim.fn.delete(lease.lock_path, "rf")
cleanup()

vim.cmd("qa!")
