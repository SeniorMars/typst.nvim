local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local requests = require("typst.integrations.tinymist.requests")
local typst = require("typst")

local function make_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { "#let x = 1" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    return bufnr
end

local original_get_clients = vim.lsp.get_clients
local pending = {}
local cancelled = {}
local next_id = 0

local client = {
    name = "tinymist",
    offset_encoding = "utf-16",
    supports_method = function(_, method)
        return method == "textDocument/hover"
    end,
    request = function(_, method, params, callback, bufnr)
        next_id = next_id + 1
        pending[next_id] = {
            method = method,
            params = params,
            callback = callback,
            bufnr = bufnr,
        }
        return true, next_id
    end,
    cancel_request = function(_, id)
        cancelled[id] = true
        return true
    end,
}

rawset(vim.lsp, "get_clients", function(opts)
    if opts and opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
        return { client }
    end
    return {}
end)

local function deliver(id, result)
    local request =
        assert(pending[id], ("missing pending request %d"):format(id))
    request.callback(nil, result or {
        contents = {
            kind = "markdown",
            value = ("hover-%d"):format(id),
        },
    })
end

local function wait_for(predicate, message)
    assert(vim.wait(1000, predicate, 10), message)
end

local function cleanup()
    require("typst.integrations.tinymist.async").reset()
    typst.reset({ force = true })
    vim.lsp.get_clients = original_get_clients
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

typst.reset()
typst.setup({
    root = root,
    integrations = {
        tinymist = {
            lsp = "detect",
        },
    },
})
local ok, err = xpcall(function()
    local bufnr = make_buffer()

    ---@type any
    local cursor_result = nil
    requests.hover(bufnr, {
        callback = function(result)
            cursor_result = result
        end,
    })
    assert(pending[1], "cursor stale test should start a Tinymist request")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    deliver(1)
    wait_for(function()
        return cursor_result ~= nil
    end, "cursor stale request did not finish")
    assert(
        cursor_result.stale and cursor_result.reason == "cursor_moved",
        "Tinymist hover should report cursor-moved stale results"
    )

    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    ---@type any
    local first_generation = nil
    ---@type any
    local second_generation = nil
    requests.hover(bufnr, {
        callback = function(result)
            first_generation = result
        end,
    })
    requests.hover(bufnr, {
        callback = function(result)
            second_generation = result
        end,
    })
    assert(pending[2] and pending[3], "generation test should start requests")
    deliver(2)
    wait_for(function()
        return first_generation ~= nil
    end, "stale generation request did not finish")
    assert(
        first_generation.stale and first_generation.reason == "stale_request",
        "older Tinymist hover request should be stale after a newer request"
    )
    deliver(3)
    wait_for(function()
        return second_generation ~= nil
    end, "fresh generation request did not finish")
    assert(
        second_generation.ok == true and not second_generation.stale,
        "newest Tinymist hover request should be accepted"
    )

    local deleted_buf = make_buffer({ "#let y = 2" })
    ---@type any
    local invalid_result = nil
    requests.hover(deleted_buf, {
        callback = function(result)
            invalid_result = result
        end,
    })
    assert(pending[4], "invalid-buffer test should start a request")
    vim.api.nvim_buf_delete(deleted_buf, { force = true })
    deliver(4)
    wait_for(function()
        return invalid_result ~= nil
    end, "invalid-buffer stale request did not finish")
    assert(
        invalid_result.stale and invalid_result.reason == "invalid_buffer",
        "Tinymist hover should reject responses after buffer deletion"
    )

    bufnr = make_buffer({ "#let z = 3" })
    local timeout_results = {}
    local timeout_handle = requests.hover(bufnr, {
        timeout_ms = 20,
        callback = function(result)
            timeout_results[#timeout_results + 1] = result
        end,
    })
    assert(
        timeout_handle and timeout_handle.pending == true,
        "timeout test should return a pending Tinymist handle"
    )
    wait_for(function()
        return timeout_results[1] ~= nil
    end, "Tinymist timeout did not fire")
    assert(
        timeout_results[1].reason == "timeout",
        "Tinymist request should report timeout"
    )
    assert(cancelled[5] == true, "Tinymist timeout should cancel LSP request")
    deliver(5)
    vim.wait(50, function()
        return #timeout_results > 1
    end, 5)
    assert(
        #timeout_results == 1,
        "late Tinymist response after timeout should be ignored"
    )

    bufnr = make_buffer({ "#let reset = 4" })
    ---@type any
    local reset_result = nil
    requests.hover(bufnr, {
        callback = function(result)
            reset_result = result
        end,
    })
    local reset_request_id = next_id
    assert(
        pending[reset_request_id],
        "reset stale test should start a Tinymist request"
    )
    typst.reset({ force = true })
    deliver(reset_request_id)
    wait_for(function()
        return reset_result ~= nil
    end, "reset-stale Tinymist request did not finish")
    assert(
        reset_result.stale and reset_result.reason == "reset",
        "Tinymist hover should reject responses after typst.nvim reset"
    )
end, debug.traceback)

cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
