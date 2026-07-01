local config = require("typst.config")
local graph_match = require("typst.project.graph_match")
local main_file = require("typst.project.main_file")
local project_model = require("typst.project.model")
local project_store = require("typst.project.store")
local root_discovery = require("typst.project.root")
local util = require("typst.core.util")

local M = {}

--- Resolve root/main data for a buffer without mutating project registry state.
---@param bufnr integer Buffer to resolve.
---@param resolve_opts? table Resolution controls such as ignored previous project key.
---@return table candidate Attachment candidate with root, main, path, and resolution metadata.
function M.resolve_candidate(bufnr, resolve_opts)
    bufnr = project_model.normalize_bufnr(bufnr)
    resolve_opts = resolve_opts or {}
    local path = project_model.current_buffer_path(bufnr)
    local scratch = false
    if not path then
        path = project_model.scratch_buffer_path(bufnr)
        scratch = true
    end

    local opts = config.unsafe_get()
    local root, root_source = root_discovery.detect(path, bufnr, opts)
    if scratch and root_source == "buffer directory" then
        root, root_source =
            util.normalize(vim.fn.getcwd()), "unnamed buffer cwd"
    end
    local main, main_source = main_file.buffer_main(bufnr, root)
    main, main_source =
        main_file.discard_unreadable(bufnr, path, main, main_source)

    if not scratch and not main then
        main, main_source = main_file.persisted(path, opts)
        main, main_source =
            main_file.discard_unreadable(bufnr, path, main, main_source)
        root, root_source = root_discovery.reconcile_for_main(
            root,
            root_source,
            path,
            main,
            main_source
        )
    end

    if not scratch and not main then
        main, main_source = main_file.directive(path, bufnr)
        main, main_source =
            main_file.discard_unreadable(bufnr, path, main, main_source)
        root, root_source = root_discovery.reconcile_for_main(
            root,
            root_source,
            path,
            main,
            main_source
        )
    end

    if not main then
        main, main_source = main_file.configured(path, bufnr, root, opts)
        main, main_source =
            main_file.discard_unreadable(bufnr, path, main, main_source)
    end

    if not scratch and not main then
        local project_root, project_root_source
        main, main_source, project_root, project_root_source =
            main_file.project_file(path)
        main, main_source =
            main_file.discard_unreadable(bufnr, path, main, main_source)
        if main and root_source == "buffer directory" then
            root, root_source = project_root, project_root_source
        end
    end

    if not scratch and not main then
        local existing, ambiguous, graph_source =
            graph_match.existing_project_for(
                project_store.all(),
                path,
                resolve_opts.ignore_project_key
            )
        if existing then
            return {
                bufnr = bufnr,
                path = path,
                root = existing.root,
                main = existing.main,
                previous_key = project_store.key_for_buffer(bufnr),
                resolution = {
                    root_source = "existing project",
                    main_source = "existing project graph",
                    graph_source = graph_source or "unknown",
                },
            }
        elseif ambiguous then
            require("typst.core.log").add(
                "info",
                "project graph attachment was ambiguous; continuing resolver fallbacks",
                { path = path }
            )
        end
    end

    if not scratch and not main then
        local scan_root, scan_root_source
        main, main_source, scan_root, scan_root_source =
            root_discovery.import_scan_main(path, root, root_source, opts)
        if main then
            root, root_source = scan_root, scan_root_source
        end
    end

    if scratch and not main then
        main, main_source = path, "unnamed buffer"
    elseif not main then
        main, main_source = main_file.heuristic(path, root)
    end

    return {
        bufnr = bufnr,
        path = path,
        root = root,
        main = main,
        previous_key = project_store.key_for_buffer(bufnr),
        resolution = {
            root_source = root_source,
            main_source = main_source,
            scratch = scratch,
        },
    }
end

return M
