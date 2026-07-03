local M = {}

function M.pending(fields)
    return vim.tbl_extend("force", {
        pending = true,
        cancel = function()
            return true, { stopped = true }
        end,
    }, fields or {})
end

function M.compiler(fields)
    fields = fields or {}
    return {
        name = fields.name or "fake-compiler-provider",
        compile = fields.compile or function()
            return { ok = true, code = 0, stale = false }
        end,
        start = fields.start or function()
            return M.pending({ kind = "watch" })
        end,
        stop = fields.stop or function(_, callback)
            if callback then
                callback({ stopped = true, code = 0, stale = false })
            end
            return { stopped = true, code = 0, stale = false }
        end,
        status = fields.status or function(project)
            return typst_test_compiler(project).status
        end,
        output = fields.output or function()
            return typst_test_cache_path("fake-provider/output.pdf")
        end,
    }
end

return M
