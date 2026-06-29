local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local lsp_request = require("typst.core.lsp_request")

local ok, err = xpcall(function()
    local cancelled = nil
    local client = {
        request = function()
            return true, 42
        end,
        cancel_request = function(_, request_id)
            cancelled = request_id
            return true
        end,
    }

    local started = lsp_request.start(client, "test/method", {}, nil, 1)
    assert(started.ok, "true/request-id request should start")
    assert(
        started.request_id == 42,
        "request helper should preserve the actual request id"
    )
    assert(lsp_request.cancel(started), "request helper should cancel starts")
    assert(cancelled == 42, "request helper should cancel the actual id")

    local numeric_first = lsp_request.normalize_start(true, 99, nil)
    assert(numeric_first.ok, "numeric-first request should be accepted")
    assert(
        numeric_first.request_id == 99,
        "numeric-first request id should be preserved"
    )

    local rejected = lsp_request.normalize_start(true, false, nil)
    assert(not rejected.ok, "false request status should be rejected")
    assert(
        rejected.reason == "request_failed",
        "rejected request should use request_failed"
    )

    local thrown = lsp_request.normalize_start(false, "boom", nil)
    assert(not thrown.ok, "thrown request should fail")
    assert(thrown.error == "boom", "thrown error should be preserved")
end, debug.traceback)

if not ok then
    error(err)
end

print("lsp_request_spec: ok")
