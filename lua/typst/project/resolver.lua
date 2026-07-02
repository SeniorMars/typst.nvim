local config = require("typst.config")
local project_model = require("typst.project.model")
local project_store = require("typst.project.store")
local graph_source = require("typst.project.resolver.graph")
local import_scan_source = require("typst.project.resolver.import_scan")
local main_source = require("typst.project.resolver.main")
local root_source = require("typst.project.resolver.root")

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
    local deferred_import_scan = nil
    if not path then
        path = project_model.scratch_buffer_path(bufnr)
        scratch = true
    end

    local opts = config.unsafe_get()
    local root, root_source_label =
        root_source.initial(path, bufnr, scratch, opts)
    local main, main_source_label = main_source.buffer(bufnr, path, root)

    if not scratch and not main then
        main, main_source_label = main_source.persisted(bufnr, path, opts)
        root, root_source_label = root_source.reconcile_for_main(
            root,
            root_source_label,
            path,
            main,
            main_source_label
        )
    end

    if not scratch and not main then
        main, main_source_label = main_source.directive(bufnr, path)
        root, root_source_label = root_source.reconcile_for_main(
            root,
            root_source_label,
            path,
            main,
            main_source_label
        )
    end

    if not main then
        main, main_source_label =
            main_source.configured(bufnr, path, root, opts)
    end

    if not scratch and not main then
        local project_root, project_root_source
        main, main_source_label, project_root, project_root_source =
            main_source.project_file(bufnr, path)
        if main and root_source_label == "buffer directory" then
            root, root_source_label = project_root, project_root_source
        end
    end

    if not scratch and not main then
        local graph_candidate =
            graph_source.existing_project(bufnr, path, resolve_opts)
        if graph_candidate then
            return graph_candidate
        end
    end

    if not scratch and not main then
        local scan_root, scan_root_source
        main, main_source_label, scan_root, scan_root_source, deferred_import_scan =
            import_scan_source.resolve(
                path,
                root,
                root_source_label,
                opts,
                resolve_opts
            )
        if deferred_import_scan then
            deferred_import_scan.config_generation = config.generation()
        end
        if main then
            root, root_source_label = scan_root, scan_root_source
        end
    end

    if not main then
        main, main_source_label = main_source.fallback(path, root, scratch)
    end

    return {
        bufnr = bufnr,
        path = path,
        root = root,
        main = main,
        previous_key = project_store.key_for_buffer(bufnr),
        resolution = {
            root_source = root_source_label,
            main_source = main_source_label,
            main_confidence = main_source.confidence_for_source(
                main_source_label
            ),
            main_confidence_source = main_source_label,
            resolution_pending = deferred_import_scan and "import_scan" or nil,
            import_scan_pending = deferred_import_scan ~= nil,
            import_scan_request = deferred_import_scan,
            scratch = scratch,
        },
    }
end

return M
