local M = {}

local log = require("typst.core.log")
local project = require("typst.project")
local project_lifecycle = require("typst.project.lifecycle")
local util = require("typst.core.util")

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

--- Build the public project API facade used by commands and `require("typst")`.
---@param opts? table API construction options.
---@return table api Project methods that resolve buffers to project state lazily.
function M.create(opts)
    opts = opts or {}
    ---@type fun(message:string, level?:integer)
    local notify = opts.notify or function(_, _) end
    local api = {}

    --- Attach one Typst buffer to its resolved project and install buffer hooks.
    ---@param bufnr? integer Buffer to attach; nil and 0 mean the current buffer.
    ---@return table|nil state Attached project state, or nil when resolution/attach fails.
    function api.attach(bufnr)
        return project_lifecycle.attach(api, bufnr)
    end

    --- Detach one buffer from its project and prune resources when it was last.
    ---@param bufnr? integer Buffer to detach; nil and 0 mean the current buffer.
    ---@return table|nil state Project state the buffer belonged to before detach.
    function api.detach(bufnr)
        return project_lifecycle.detach(bufnr)
    end

    --- Return a fresh project state for a buffer, re-resolving stale main choices.
    ---@param bufnr? integer Buffer whose Typst project should be resolved.
    ---@return table state Project state associated with the buffer.
    function api.get_project(bufnr)
        return project_lifecycle.get_project(bufnr)
    end

    function api.snapshot(bufnr, snapshot_opts)
        local state = api.get_project(bufnr)
        return project.snapshot(state, snapshot_opts)
    end

    function api.projects(opts)
        return project.all_snapshots(opts)
    end

    --- Set an explicit main file for a buffer and reattach project services.
    ---@param path string Main Typst file path selected by the user.
    ---@param bufnr? integer Buffer receiving the explicit main setting.
    ---@param set_opts? table Main-file persistence and resolution options.
    ---@return table state Project state after the main-file change.
    function api.set_main(path, bufnr, set_opts)
        return project_lifecycle.set_main(path, bufnr, set_opts, notify)
    end

    --- Toggle the current buffer between local-main and project-main behavior.
    ---@param toggle_opts? table Toggle controls, including `bufnr` and `notify`.
    ---@return table result Toggle result with `local_main` and project `state`.
    function api.toggle_main(toggle_opts)
        return project_lifecycle.toggle_main(toggle_opts, notify)
    end

    function api.edit_main(edit_opts)
        edit_opts = edit_opts or {}
        local state = api.get_project(edit_opts.bufnr)
        util.edit_existing_or_path(state.main)
        notify(
            ("Editing Typst main: %s"):format(
                util.relpath(state.main, state.root)
            )
        )
        return state.main
    end

    function api.cd(cd_opts)
        cd_opts = cd_opts or {}
        local state = api.get_project(cd_opts.bufnr)
        local command = cd_opts.global and "cd" or "lcd"
        vim.cmd(command .. " " .. vim.fn.fnameescape(state.root))
        log.add("info", "changed directory to project root", {
            root = state.root,
            scope = cd_opts.global and "global" or "window",
        })
        notify(("Typst root: %s"):format(state.root))
        return state.root
    end

    --- Rebuild project attachment and metadata caches for a buffer.
    ---@param reload_opts? table Reload controls, including `bufnr` and `notify`.
    ---@return table state Reattached project state.
    function api.reload_state(reload_opts)
        return project_lifecycle.reload_state(api, reload_opts, notify)
    end

    --- Clear derived metadata, completion, package, index, and conceal caches.
    ---@param cache_opts? table Cache controls, including `bufnr` and `notify`.
    ---@return table summary Cache groups that were cleared.
    function api.clear_cache(cache_opts)
        cache_opts = cache_opts or {}
        require("typst.metadata").reset()
        require("typst.completion").reset()
        require("typst.package").reset()
        require("typst.metadata.symbol").reset()
        require("typst.index").reset()
        require("typst.core.treesitter").forget(cache_opts.bufnr)
        require("typst.conceal").refresh(cache_opts.bufnr)

        log.add("info", "caches cleared", {
            bufnr = cache_opts.bufnr,
            metadata = true,
            completion = true,
            package = true,
            symbol = true,
            index = true,
            treesitter = true,
            conceal = true,
        })

        if cache_opts.notify ~= false then
            notify(
                "Cleared Typst metadata, completion, package, symbol, Tree-sitter, project index, and conceal caches"
            )
        end

        return {
            metadata = true,
            completion = true,
            package = true,
            symbol = true,
            index = true,
            treesitter = true,
            conceal = true,
        }
    end

    return api
end

return M
