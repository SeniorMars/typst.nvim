local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local completion_lsp = require("typst.completion.lsp")
local config = require("typst.config")
local tinymist = require("typst.integrations.tinymist")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    completion = {
        package_cache_prewarm = false,
        tinymist_timeout_ms = 20,
    },
})

local original_clients = tinymist.clients
local original_select_client = tinymist.select_client
local request_count = 0
local cancelled = 0
local callbacks = {}
local client = {
    id = 177,
    name = "tinymist-timeout-test",
    supports_method = function()
        return true
    end,
    request = function(_, method, _params, handler)
        assert(method == "textDocument/completion", "unexpected method")
        request_count = request_count + 1
        callbacks[request_count] = handler
        return true, request_count
    end,
    cancel_request = function(_, request_id)
        cancelled = cancelled + 1
        assert(type(request_id) == "number", "request id should be numeric")
        return true
    end,
}
tinymist.clients = function()
    return { client }
end
tinymist.select_client = function()
    return {
        ok = true,
        provider = "tinymist",
        client = client,
        clients = { client },
    }
end

local bufnr = vim.api.nvim_create_buf(true, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "#foo" })

local waiter_items = nil
local function request(session)
    return completion_lsp.items({
        bufnr = bufnr,
        position = { line = 0, character = 4 },
        completion_context = {},
        include_tinymist = true,
        completion_session = session,
        on_tinymist_results = function(items)
            waiter_items = items
        end,
    }, "fo", "markup")
end

local first = request("first")
assert(#first == 0, "initial async completion should return no items")
assert(request_count == 1, "first request should start LSP completion")

local second = request("first")
assert(#second == 0, "pending completion should not return items")
assert(request_count == 1, "same pending key should not start another request")

assert(
    vim.wait(1000, function()
        return cancelled == 1 and waiter_items ~= nil
    end, 10),
    "pending Tinymist completion should time out and notify waiters"
)
assert(#waiter_items == 0, "timeout waiter should receive an empty item list")

waiter_items = nil
local retry = request("retry")
assert(#retry == 0, "retry should remain async")
assert(request_count == 2, "timed-out completion should be retryable")

completion_lsp.reset()
assert(
    type(waiter_items) == "table" and #waiter_items == 0,
    "completion reset should notify pending Tinymist waiters with empty items"
)
assert(
    cancelled >= 2,
    "completion reset should cancel pending Tinymist requests"
)

completion_lsp.reset()
cancelled = 0
request_count = 0
callbacks = {}
waiter_items = nil
config.unsafe_get().completion.tinymist_timeout_ms = 0
local error_items = request("error")
assert(#error_items == 0, "error fixture should start async request")
assert(request_count == 1, "error fixture should start one LSP request")
callbacks[1]("synthetic Tinymist error", nil)
assert(
    vim.wait(1000, function()
        return waiter_items ~= nil
    end, 10),
    "Tinymist completion error should notify waiters"
)
assert(
    type(waiter_items) == "table" and #waiter_items == 0,
    "Tinymist completion error waiter should receive empty items"
)
waiter_items = nil
local after_error = request("after-error")
assert(#after_error == 0, "after-error retry should remain async")
assert(
    request_count == 2,
    "Tinymist completion error should delete cache entry for retry"
)

completion_lsp.reset()
local original_request = client.request
request_count = 0
waiter_items = nil
client.request = function()
    request_count = request_count + 1
    return false
end
local start_failure = request("start-failure")
assert(#start_failure == 0, "start-failure request should return no items")
assert(request_count == 1, "start-failure fixture should call request once")
assert(
    vim.wait(1000, function()
        return waiter_items ~= nil
    end, 10),
    "Tinymist request start failure should notify waiters"
)
assert(
    type(waiter_items) == "table" and #waiter_items == 0,
    "Tinymist request start failure waiter should receive empty items"
)
client.request = original_request

completion_lsp.reset()
cancelled = 0
request_count = 0
callbacks = {}
config.unsafe_get().completion.tinymist_timeout_ms = 0
local eviction_notifications = 0
local evicted_items = nil
for index = 1, 65 do
    local items = completion_lsp.items({
        bufnr = bufnr,
        position = { line = 0, character = index },
        completion_context = {},
        include_tinymist = true,
        completion_session = "evict-" .. index,
        on_tinymist_results = index == 1 and function(items)
            eviction_notifications = eviction_notifications + 1
            evicted_items = items
        end or nil,
    }, "fo", "markup")
    assert(#items == 0, "pending eviction request should remain async")
end
assert(request_count == 65, "eviction fixture should start unique requests")
assert(
    cancelled >= 1,
    "completion cache eviction should cancel forgotten pending LSP requests"
)
assert(
    eviction_notifications == 1,
    "completion cache eviction should notify evicted waiters once"
)
assert(
    type(evicted_items) == "table" and #evicted_items == 0,
    "completion cache eviction waiter should receive empty items"
)

completion_lsp.reset()
tinymist.clients = original_clients
tinymist.select_client = original_select_client
typst.reset({ force = true })

vim.cmd("qa!")
