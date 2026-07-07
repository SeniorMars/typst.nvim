local M = {}

---Return declarative runtime project policies keyed by public symbol.
---@return table<string, table> policies Runtime API policy map.
function M.policies()
    return require("typst.api.runtime_spec").policies()
end

---Return runtime endpoint policy metadata.
---@return table status Runtime API policy status.
function M.status()
    return require("typst.api.runtime_spec").status()
end

---Install runtime adapter entrypoints from the declarative runtime spec.
---@param api table Public API table that receives runtime-backed methods.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification callback.
---@param normalize_bufnr fun(bufnr?:integer):integer Buffer normalizer.
function M.install(api, notify, normalize_bufnr)
    require("typst.api.runtime_dispatch").install(
        api,
        require("typst.api.runtime_spec").endpoints,
        {
            notify = notify,
            normalize_bufnr = normalize_bufnr,
        }
    )
end

return M
