local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local request_async = require("typst.integrations.tinymist.async")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typst"

local fake_client = {
    id = 99042,
    name = "tinymist",
    supports_method = function()
        return true
    end,
    request = function(_, _method, _params, callback)
        callback(nil, { ok = true })
        return true, 1
    end,
}

local callback_result = nil
local pending = request_async.request(
    bufnr,
    "tinymist/testNormalize",
    function()
        return {}
    end,
    {
        client = fake_client,
        guard_cursor = false,
        timeout_ms = 0,
    },
    function(result)
        callback_result = result
    end,
    function()
        return nil
    end
)

assert(
    pending and pending.pending,
    "Tinymist request should return a pending handle"
)
assert(
    vim.wait(1000, function()
        return callback_result ~= nil
    end, 10),
    "Tinymist normalize failure callback should run"
)
assert(
    callback_result.ok == false
        and callback_result.reason == "normalize_failed"
        and callback_result.provider == "tinymist",
    "Tinymist nil normalize result should become a structured failure"
)
assert(
    callback_result.message:find("normalizer returned no result", 1, true),
    "Tinymist nil normalize result should include an actionable message"
)

vim.cmd("qa!")
