local M = {}

local reset_hooks = {
    {
        name = "preview.follow_buffer",
        module = "typst.preview.follow_buffer",
        method = "reset",
    },
    {
        name = "project.lifecycle",
        module = "typst.project.lifecycle",
        method = "reset",
    },
    {
        name = "project.attachments",
        module = "typst.project.attachments",
        method = "reset",
    },
    {
        name = "completion",
        module = "typst.completion",
        method = "reset",
        loaded_only = true,
    },
    {
        name = "conceal",
        module = "typst.conceal",
        method = "reset",
        loaded_only = true,
    },
    {
        name = "diagnostics",
        module = "typst.diagnostics",
        method = "reset",
        loaded_only = true,
    },
}

local function module_for(entry)
    if entry.loaded_only then
        return package.loaded[entry.module]
    end
    return require(entry.module)
end

--- Reset global runtime hooks in a stable, documented order.
---
--- Resource/process shutdown happens before this registry. These hooks clear
--- session-global autocmds, delayed resolver tokens, and loaded editor caches
--- that are not naturally tied to a single project object.
---@param opts? table Reset controls, reserved for hook-specific policies.
---@return table<string, table> summary Hook names keyed by structured reset status.
function M.reset(opts)
    opts = opts or {}
    local summary = {}
    for _, entry in ipairs(reset_hooks) do
        local ok, module_or_err = pcall(module_for, entry)
        if ok and type(module_or_err) == "table" then
            local method = module_or_err[entry.method]
            if type(method) == "function" then
                local called, err = pcall(method, opts)
                summary[entry.name] = called and { ok = true, status = "reset" }
                    or {
                        ok = false,
                        status = "error",
                        error = tostring(err),
                    }
                if not called then
                    require("typst.core.log").add(
                        "warn",
                        "runtime reset hook failed",
                        {
                            name = entry.name,
                            module = entry.module,
                            error = err,
                        }
                    )
                end
            else
                summary[entry.name] = {
                    ok = false,
                    status = "missing_method",
                }
            end
        else
            if entry.loaded_only and module_or_err == nil then
                summary[entry.name] = {
                    ok = true,
                    status = "skipped_unloaded",
                }
            else
                summary[entry.name] = {
                    ok = false,
                    status = "error",
                    error = tostring(module_or_err),
                }
            end
            if not entry.loaded_only then
                require("typst.core.log").add(
                    "warn",
                    "runtime reset hook module failed",
                    {
                        name = entry.name,
                        module = entry.module,
                        error = module_or_err,
                    }
                )
            end
        end
    end
    return summary
end

--- Return runtime reset hook metadata for health/tests.
---@return table[] hooks Ordered runtime hook descriptions.
function M.status()
    local hooks = {}
    for _, entry in ipairs(reset_hooks) do
        hooks[#hooks + 1] = {
            name = entry.name,
            module = entry.module,
            method = entry.method,
            loaded_only = entry.loaded_only == true,
            loaded = package.loaded[entry.module] ~= nil,
        }
    end
    return hooks
end

return M
