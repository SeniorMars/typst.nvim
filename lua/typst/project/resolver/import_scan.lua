local root_discovery = require("typst.project.root")

local M = {}

---Resolve or defer import-scan fallback main discovery.
---@param path string Buffer path.
---@param root string Current root candidate.
---@param root_source string Current root source.
---@param opts table Plugin configuration.
---@param resolve_opts table Resolver controls.
---@return string? main Import-scan main.
---@return string? main_source Import-scan source label.
---@return string? root Resolved root when a scan matched.
---@return string? root_source Resolved root source when a scan matched.
---@return table? pending Deferred scan request.
function M.resolve(path, root, root_source, opts, resolve_opts)
    if not (opts.project and opts.project.import_scan) then
        return nil
    end

    if resolve_opts.import_scan == "defer" then
        return nil,
            nil,
            nil,
            nil,
            {
                path = path,
                root = root,
                root_source = root_source,
            }
    end

    if resolve_opts.import_scan == false then
        return nil
    end

    local scan_root, scan_root_source
    local main, main_source
    main, main_source, scan_root, scan_root_source =
        root_discovery.import_scan_main(path, root, root_source, opts)
    if main then
        return main, main_source, scan_root, scan_root_source
    end
end

return M
