local config = require("typst.config")
local project_model = require("typst.project.model")
local project_store = require("typst.project.store")
local graph_source = require("typst.project.resolver.graph")
local import_scan_source = require("typst.project.resolver.import_scan")
local main_source = require("typst.project.resolver.main")
local root_discovery = require("typst.project.root")
local root_source = require("typst.project.resolver.root")

local M = {}

local function record(trace, stage, status, fields)
    local entry = vim.tbl_extend("force", {
        stage = stage,
        status = status,
    }, fields or {})
    trace[#trace + 1] = entry
    return entry
end

local function record_main(trace, stage, main, source)
    record(trace, stage, main and "matched" or "skipped", {
        main = main,
        source = source,
        confidence = source and main_source.confidence_for_source(source)
            or nil,
    })
end

--- Resolve root/main data for a buffer without mutating project registry state.
---@param bufnr integer Buffer to resolve.
---@param resolve_opts? table Resolution controls such as ignored previous project key.
---@return table candidate Attachment candidate with root, main, path, and resolution metadata.
function M.resolve_candidate(bufnr, resolve_opts)
    bufnr = project_model.normalize_bufnr(bufnr)
    resolve_opts = resolve_opts or {}
    local trace = {}
    local path = project_model.current_buffer_path(bufnr)
    local scratch = false
    local deferred_import_scan = nil
    if not path then
        path = project_model.scratch_buffer_path(bufnr)
        scratch = true
    end
    path = assert(path)

    local opts = config.unsafe_get()
    local root, root_source_label =
        root_source.initial(path, bufnr, scratch, opts)
    record(trace, "root", "matched", {
        root = root,
        source = root_source_label,
    })

    local main, main_source_label =
        main_source.buffer(bufnr, path, root, resolve_opts)
    record_main(trace, "buffer_main", main, main_source_label)

    if not scratch and not main then
        main, main_source_label = main_source.persisted(bufnr, path, opts)
        record_main(trace, "saved_main", main, main_source_label)
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
        record_main(trace, "directive", main, main_source_label)
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
        record_main(trace, "configured_main", main, main_source_label)
        if not scratch then
            root, root_source_label = root_source.reconcile_for_main(
                root,
                root_source_label,
                path,
                main,
                main_source_label
            )
        end
    end

    if not scratch and not main then
        local project_root, project_root_source
        main, main_source_label, project_root, project_root_source =
            main_source.project_file(bufnr, path)
        record(trace, ".typstmain", main and "matched" or "skipped", {
            main = main,
            source = main_source_label,
            root = project_root,
            root_source = project_root_source,
            confidence = main_source_label
                    and main_source.confidence_for_source(main_source_label)
                or nil,
        })
        if
            main
            and project_root
            and project_root_source
            and root_source_label == "buffer directory"
        then
            root, root_source_label = project_root, project_root_source
        end
    end

    if not scratch and not main then
        local graph_candidate =
            graph_source.existing_project(bufnr, path, resolve_opts)
        if graph_candidate then
            record(trace, "existing_project_graph", "matched", {
                main = graph_candidate.main,
                root = graph_candidate.root,
                source = graph_candidate.resolution
                        and graph_candidate.resolution.main_source
                    or "existing project graph",
                confidence = graph_candidate.resolution
                        and graph_candidate.resolution.main_confidence
                    or main_source.confidence_for_source(
                        "existing project graph"
                    ),
            })
            graph_candidate.resolution = graph_candidate.resolution or {}
            graph_candidate.resolution.trace = trace
            graph_candidate.resolution.import_scan_line_limit =
                root_discovery.import_scan_line_limit()
            return graph_candidate
        end
        record(trace, "existing_project_graph", "skipped")
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
        record(
            trace,
            "import_scan",
            main and "matched"
                or (deferred_import_scan and "deferred" or "not_found"),
            {
                main = main,
                source = main_source_label,
                root = scan_root,
                root_source = scan_root_source,
                confidence = main_source_label
                        and main_source.confidence_for_source(main_source_label)
                    or nil,
                line_limit = root_discovery.import_scan_line_limit(),
                max_files = opts.project and opts.project.import_scan_max_files
                    or nil,
                max_depth = opts.project and opts.project.import_scan_max_depth
                    or nil,
                max_entries = opts.project
                        and opts.project.import_scan_max_entries
                    or nil,
            }
        )
        if main and scan_root and scan_root_source then
            root, root_source_label = scan_root, scan_root_source
        end
    end

    if not main then
        main, main_source_label = main_source.fallback(path, root, scratch)
        record_main(trace, "fallback", main, main_source_label)
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
            import_scan_line_limit = root_discovery.import_scan_line_limit(),
            trace = trace,
            allow_unreadable_explicit_main = resolve_opts.allow_unreadable_explicit_main
                        == true
                    and main_source_label == "buffer variable vim.b.typst_main"
                or nil,
            scratch = scratch,
        },
    }
end

return M
