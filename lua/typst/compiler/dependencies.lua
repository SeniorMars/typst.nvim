local log = require("typst.core.log")
local async = require("typst.core.async")
local project_registry = require("typst.project")
local compiler_service = require("typst.project.services.compiler")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop
local initial_poll_ms = 100
local fast_poll_ms = 250
local medium_poll_ms = 1000
local slow_poll_ms = 2000
local medium_after_unchanged = 4
local slow_after_unchanged = 12

--- Delete a temporary Typst dependency JSON file if it exists.
---@param path? string Path to the dependency file.
function M.cleanup_file(path)
    if path and vim.fn.filereadable(path) == 1 then
        local ok, err = util.delete_checked(path)
        if not ok then
            log.add(
                "warn",
                "failed to delete Typst dependency file",
                { path = path, error = err }
            )
        end
    end
end

local function dependency_inputs(decoded)
    if type(decoded) ~= "table" then
        return nil
    end

    local inputs = decoded.inputs
    if inputs == nil then
        return {}
    end
    if type(inputs) ~= "table" then
        return nil
    end

    local deps = {}
    for index, value in ipairs(inputs) do
        if type(value) ~= "string" or value == "" then
            log.add("warn", "ignored invalid Typst dependency input", {
                index = index,
                type = type(value),
            })
        else
            deps[#deps + 1] = value
        end
    end

    return deps
end

--- Read and normalize dependency inputs from a Typst dependency JSON file.
---@param path? string Dependency JSON file path.
---@param root string Project root used to resolve relative dependency paths.
---@param opts? table Options; `quiet` suppresses parse/schema warnings.
---@return string[]? deps Normalized dependency paths, or nil when unavailable/invalid.
function M.read(path, root, opts)
    opts = opts or {}
    if not path or vim.fn.filereadable(path) ~= 1 then
        return nil
    end

    local ok, decoded =
        pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if not ok then
        if not opts.quiet then
            log.add(
                "warn",
                "failed to parse Typst dependency JSON",
                { path = path }
            )
        end
        return nil
    end

    local deps = dependency_inputs(decoded)
    if not deps then
        if not opts.quiet then
            log.add(
                "warn",
                "Typst dependency JSON has an unsupported schema",
                { path = path }
            )
        end
        return nil
    end

    local seen = {}
    local normalized = {}
    for _, dep in ipairs(deps) do
        local resolved = util.resolve_path(dep, root)
        if not seen[resolved] then
            seen[resolved] = true
            normalized[#normalized + 1] = resolved
        end
    end
    return normalized
end

--- Read dependencies and remove the temporary dependency JSON file.
---@param path? string Dependency JSON file path.
---@param root string Project root used to resolve relative dependency paths.
---@return string[]? deps Normalized dependency paths, or nil when unavailable/invalid.
function M.take(path, root)
    local deps = M.read(path, root)
    M.cleanup_file(path)
    return deps
end

--- Update the project registry with compiler-discovered dependencies.
---@param project table Project state whose dependency graph should be updated.
---@param deps? string[] Normalized dependency paths.
function M.update_project(project, deps)
    if deps then
        project_registry.update_dependencies(project, deps)
    end
end

local function signature(path)
    if not path then
        return nil
    end

    local stat = uv.fs_stat(path)
    if not stat then
        return nil
    end

    return ("%d:%d:%d"):format(
        stat.size or 0,
        stat.mtime.sec or 0,
        stat.mtime.nsec or 0
    )
end

--- Refresh a watcher's dependency list when its dependency JSON changed.
---@param project table Project state whose dependencies may be updated.
---@param watcher table Watcher state containing dependency file metadata.
---@return boolean changed True when dependencies were read and published.
function M.refresh_watcher(project, watcher)
    if not watcher or not watcher.deps_path then
        return false
    end

    local deps_signature = signature(watcher.deps_path)
    if not deps_signature or deps_signature == watcher.deps_signature then
        return false
    end

    local deps = M.read(watcher.deps_path, project.root, { quiet = true })
    if not deps then
        return false
    end

    watcher.deps_signature = deps_signature
    M.update_project(project, deps)
    log.add("debug", "watch dependencies updated", {
        main = project.main,
        count = #deps,
    })
    return true
end

--- Stop the dependency polling timer for a watcher.
---@param watcher? table Watcher state that may own a dependency timer.
function M.stop_poll(watcher)
    if not watcher or not watcher.deps_timer then
        return
    end

    local timer = watcher.deps_timer
    watcher.deps_timer = nil
    async.close_timer(timer)
end

--- Compute the next dependency polling delay for a watcher.
---@param watcher table Watcher state whose unchanged-poll count is updated.
---@param changed boolean True when the last poll observed dependency changes.
---@return integer milliseconds Delay before the next poll.
function M.next_poll_delay(watcher, changed)
    if changed then
        watcher.deps_unchanged_polls = 0
        return fast_poll_ms
    end

    watcher.deps_unchanged_polls = (watcher.deps_unchanged_polls or 0) + 1
    if watcher.deps_unchanged_polls >= slow_after_unchanged then
        return slow_poll_ms
    end
    if watcher.deps_unchanged_polls >= medium_after_unchanged then
        return medium_poll_ms
    end
    return fast_poll_ms
end

local function timer_is_closing(timer)
    return type(timer.is_closing) == "function" and timer:is_closing()
end

--- Start adaptive polling for a watcher's dependency JSON file.
---@param project table Project state whose active watcher is being polled.
---@param watcher table Watcher state that owns the dependency timer.
function M.start_poll(project, watcher)
    if not watcher or not watcher.deps_path then
        return
    end

    local timer = uv.new_timer()
    if not timer then
        return
    end
    watcher.deps_timer = timer
    local function schedule_next(delay)
        if watcher.deps_timer ~= timer or timer_is_closing(timer) then
            return
        end

        timer:start(
            delay,
            0,
            vim.schedule_wrap(function()
                if
                    (compiler_service.get(project) or {}).watcher ~= watcher
                    or watcher.stopping
                then
                    M.stop_poll(watcher)
                    return
                end

                local changed = M.refresh_watcher(project, watcher)
                schedule_next(M.next_poll_delay(watcher, changed))
            end)
        )
    end

    schedule_next(initial_poll_ms)
end

return M
