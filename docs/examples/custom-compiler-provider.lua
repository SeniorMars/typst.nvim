-- Small custom compiler provider. It delegates one-shot compilation to
-- `typst compile` while still using typst.nvim's provider lifecycle and output
-- ownership. Production providers must not report `stopped = true` until the
-- process has actually exited; this example keeps stop pending until vim.system
-- calls back. It intentionally does not implement watch/start mode.
local typst = require("typst")

local provider = {}
local active = {}

local function key_for(project)
    return project.key or ((project.root or "") .. "\0" .. (project.main or ""))
end

function provider.output(project)
    local stem = vim.fn.fnamemodify(project.main, ":t:r")
    return vim.fs.joinpath(project.root, stem .. ".pdf")
end

function provider.status(project)
    local entry = active[key_for(project)]
    if entry and entry.stopping then
        return "stopping"
    end
    return entry and "running" or "idle"
end

function provider.compile(project, callback)
    local key = key_for(project)
    local output = provider.output(project)
    local handle
    handle = vim.system(
        { "typst", "compile", project.main, output },
        { cwd = project.root, text = true },
        function(result)
            vim.schedule(function()
                local current = active[key]
                if not current or current.handle ~= handle then
                    return
                end
                active[key] = nil
                if current.stopping then
                    local stop_result = {
                        stopped = true,
                        code = result.code,
                        stdout = result.stdout or "",
                        stderr = result.stderr or "",
                        reason = current.stop_reason or "stopped",
                    }
                    if current.stop_callback then
                        current.stop_callback(stop_result)
                    end
                    return
                end

                callback({
                    code = result.code,
                    stdout = result.stdout or "",
                    stderr = result.stderr or "",
                    output = output,
                    stopped = current.cancelled == true or nil,
                    reason = current.cancel_reason,
                })
            end)
        end
    )

    local pending = {
        pending = true,
        handle = handle,
        cancel = function(_, opts)
            local current = active[key]
            if current and current.handle == handle then
                current.cancelled = true
                current.cancel_reason = opts and opts.reason or "cancelled"
            end
            pcall(function()
                handle:kill(15)
            end)
            return true,
                {
                    pending = true,
                    reason = opts and opts.reason or "cancelled",
                }
        end,
    }
    active[key] = pending
    return pending
end

function provider.start(_project, _callback)
    return {
        ok = false,
        reason = "unsupported",
        message = "example-compiler implements one-shot compile only, not watch mode",
    }
end

function provider.stop(project, callback)
    local key = key_for(project)
    local pending = active[key]
    if not pending then
        local result = { stopped = true, code = 0, idle = true }
        if callback then
            callback(result)
        end
        return result
    end

    pending.stopping = true
    pending.stop_reason = "stopped"
    pending.stop_callback = callback
    pcall(function()
        pending.handle:kill(15)
    end)
    return {
        pending = true,
        cancel = function()
            pcall(function()
                pending.handle:kill(9)
            end)
            return true,
                {
                    pending = true,
                    reason = "force_cancelled",
                }
        end,
    }
end

typst.providers.register("compiler", "example-compiler", provider)

typst.setup({
    compile = {
        provider = "example-compiler",
    },
})
