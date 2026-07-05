local lexical = require("typst.syntax.lexical")
local log = require("typst.core.log")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local M = {}

local uv = vim.uv or vim.loop
local IMPORT_SCAN_CACHE_TTL_MS = 1000
local import_scan_cache = {}
local import_scan_stats = {
    attempts = 0,
    cache_hits = 0,
    scans = 0,
    entries = 0,
    files = 0,
    reads = 0,
    last_elapsed_ms = 0,
    last_hit_limit = false,
    last_hit_entry_limit = false,
    last_entries = 0,
    last_max_entries = 0,
    skipped_roots = 0,
    last_skipped_root = nil,
}

local function configured_root(path, bufnr, opts)
    if type(opts.root) == "function" then
        local ok, root = xpcall(function()
            return opts.root(bufnr, path)
        end, debug.traceback)
        if not ok then
            log.add("warn", "Typst root callback failed", {
                bufnr = bufnr,
                path = path,
                error = root,
            })
            return nil
        end
        return root and util.resolve_path(root, util.dirname(path)),
            "config.root callback"
    end

    if type(opts.root) == "string" then
        return util.resolve_path(opts.root, util.dirname(path)), "config.root"
    end
end

function M.path_within(path, root)
    return util.path_within(path, root)
end

local function root_from_main_mapping(path, opts)
    if type(opts.main) ~= "table" then
        return nil
    end

    local best_root = nil
    for configured_root_path in pairs(opts.main) do
        local root = util.normalize(configured_root_path)
        if
            M.path_within(path, root) and (not best_root or #root > #best_root)
        then
            best_root = root
        end
    end

    if best_root then
        return best_root, "config.main table root"
    end
end

local function root_marker(root, markers)
    for _, marker in ipairs(markers or {}) do
        local candidate = util.join(root, marker)
        if
            vim.fn.filereadable(candidate) == 1
            or vim.fn.isdirectory(candidate) == 1
        then
            return marker
        end
    end
end

--- Resolve the Typst project root for a buffer path.
---@param path string Buffer path used as the discovery anchor.
---@param bufnr integer Buffer number passed to configured root callbacks.
---@param opts table Project configuration containing root markers and callbacks.
---@return string root Resolved project root path.
---@return string? source Human-readable source of the root decision.
function M.detect(path, bufnr, opts)
    local root, source = configured_root(path, bufnr, opts)
    if root then
        return root, source
    end

    root, source = root_from_main_mapping(path, opts)
    if root then
        return root, source
    end

    if vim.fs.root then
        root = vim.fs.root(path, opts.root_markers)
        if root then
            root = util.normalize(root)
            local marker = root_marker(root, opts.root_markers)
            return root, marker and ("root marker " .. marker) or "root marker"
        end
    end

    return util.dirname(path), "buffer directory"
end

local function skip_dir_set(project_opts)
    local set = {}
    for _, name in ipairs(project_opts.import_scan_skip_dirs or {}) do
        set[name] = true
    end
    return set
end

local function skip_scan_dir(name, skip_dirs)
    return skip_dirs[name] == true
end

local REMAINING_SCAN_DIR_BUDGET = 64

local function queue_item(dir, depth)
    return {
        dir = dir,
        depth = depth or 0,
    }
end

local function item_dir_depth(item)
    if type(item) == "table" then
        return item.dir, item.depth or 0
    end
    return item, 0
end

local function can_descend(depth, max_depth)
    return max_depth == nil or depth < max_depth
end

local function scan_has_remaining_candidates(
    handle,
    current_dir,
    current_depth,
    queue,
    count_entry,
    skip_dirs,
    max_depth
)
    local pending = vim.deepcopy(queue or {})
    while handle do
        local name, kind = uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if type(count_entry) == "function" and not count_entry() then
            return false, true
        end
        if kind == "file" and name:match("%.typ$") then
            return true, false
        end
        if
            kind == "directory"
            and can_descend(current_depth, max_depth)
            and not skip_scan_dir(name, skip_dirs)
        then
            pending[#pending + 1] =
                queue_item(util.join(current_dir, name), current_depth + 1)
        end
    end

    local seen = {}
    local checked = 0
    while #pending > 0 and checked < REMAINING_SCAN_DIR_BUDGET do
        local pending_dir, depth = item_dir_depth(table.remove(pending, 1))
        local dir = util.normalize(pending_dir)
        if not seen[dir] then
            seen[dir] = true
            checked = checked + 1
            local dir_handle = uv.fs_scandir(dir)
            while dir_handle do
                local name, kind = uv.fs_scandir_next(dir_handle)
                if not name then
                    break
                end
                if type(count_entry) == "function" and not count_entry() then
                    return false, true
                end
                if kind == "file" and name:match("%.typ$") then
                    return true, false
                end
                if
                    kind == "directory"
                    and can_descend(depth, max_depth)
                    and not skip_scan_dir(name, skip_dirs)
                then
                    pending[#pending + 1] =
                        queue_item(util.join(dir, name), depth + 1)
                end
            end
        end
    end

    return false, false
end

local function collect_typst_files(
    root,
    limit,
    entry_limit,
    skip_dirs,
    max_depth
)
    local files = {}
    local queue = { queue_item(root, 0) }
    local seen_dirs = {}
    local hit_limit = false
    local entries = 0
    local hit_entry_limit = false

    local function count_entry()
        entries = entries + 1
        if entry_limit and entries > entry_limit then
            hit_entry_limit = true
            return false
        end
        return true
    end

    while #queue > 0 and #files < limit and not hit_entry_limit do
        local item = table.remove(queue, 1)
        local dir, depth = item_dir_depth(item)
        dir = util.normalize(dir)
        if not seen_dirs[dir] then
            seen_dirs[dir] = true
            local handle = uv.fs_scandir(dir)
            while handle and #files < limit and not hit_entry_limit do
                local name, kind = uv.fs_scandir_next(handle)
                if not name then
                    break
                end
                if not count_entry() then
                    break
                end

                local full = util.join(dir, name)
                if kind == "file" and name:match("%.typ$") then
                    files[#files + 1] = util.normalize(full)
                    if #files >= limit then
                        local has_remaining, helper_hit_entry_limit =
                            scan_has_remaining_candidates(
                                handle,
                                dir,
                                depth,
                                queue,
                                count_entry,
                                skip_dirs,
                                max_depth
                            )
                        hit_limit = has_remaining == true
                        if helper_hit_entry_limit then
                            hit_entry_limit = true
                        end
                        break
                    end
                elseif
                    kind == "directory"
                    and can_descend(depth, max_depth)
                    and not skip_scan_dir(name, skip_dirs)
                then
                    queue[#queue + 1] = queue_item(full, depth + 1)
                end
            end
        end
    end

    return files,
        hit_limit,
        {
            entries = entries,
            hit_entry_limit = hit_entry_limit,
        }
end

local function add_local_typst_reference(refs, value, base, root)
    if type(value) ~= "string" or value == "" or value:sub(1, 1) == "@" then
        return
    end

    if not value:match("%.typ$") then
        return
    end

    if value:sub(1, 1) == "/" and root then
        refs[#refs + 1] = util.resolve_path(value:sub(2), root)
        return
    end

    refs[#refs + 1] = util.resolve_path(value, base)
end

local function import_scan_code_lines(lines)
    return lexical.mask_lines(lines, {
        strings = "keep",
        comments = "space",
        raw = "space",
    })
end

local function import_references(line, base, root)
    local refs = {}
    local code_line = lexical.mask_line(line, {
        strings = "keep",
        comments = "space",
        raw = "space",
    })
    local function scan(pattern)
        local search_at = 1
        while true do
            local start_col, end_col, value = code_line:find(pattern, search_at)
            if not start_col then
                break
            end
            add_local_typst_reference(refs, value, base, root)
            search_at = end_col + 1
        end
    end

    scan('#%s*include%s*"([^"]+)"')
    scan('#%s*import%s*"([^"]+)"')
    return refs
end

local function references_file(candidate, path, root, stats)
    if stats then
        stats.reads = (stats.reads or 0) + 1
    end
    local ok, lines = pcall(vim.fn.readfile, candidate, "", 500)
    if not ok then
        return false
    end

    local base = util.dirname(candidate)
    for _, line in ipairs(import_scan_code_lines(lines)) do
        for _, ref in ipairs(import_references(line, base, root)) do
            if util.same_path(ref, path) then
                return true
            end
        end
    end

    return false
end

local function now_ms()
    return math.floor(uv.hrtime() / 1000000)
end

local function import_scan_key(path, root, root_source, project_opts)
    local config_generation = 0
    local ok, config = pcall(require, "typst.config")
    if ok and type(config.generation) == "function" then
        config_generation = config.generation()
    end
    local root_stat = uv.fs_stat(root) or {}
    local root_mtime = root_stat.mtime or {}
    local skip_dirs = vim.deepcopy(project_opts.import_scan_skip_dirs or {})
    table.sort(skip_dirs)
    return table.concat({
        util.path_key(path),
        util.path_key(root),
        tostring(root_source or ""),
        tostring(project_opts.import_scan_max_files or 200),
        tostring(project_opts.import_scan_max_depth or 0),
        tostring(
            project_opts.import_scan_max_descendant_depth == nil and "unlimited"
                or project_opts.import_scan_max_descendant_depth
        ),
        tostring(project_opts.import_scan_max_entries or 2000),
        table.concat(skip_dirs, "\0"),
        tostring(config_generation),
        tostring(root_stat.size or 0),
        tostring(root_mtime.sec or 0),
        tostring(root_mtime.nsec or 0),
    }, "\n")
end

local function cached_import_scan(key)
    local entry = import_scan_cache[key]
    if not entry or entry.expires_at_ms < now_ms() then
        import_scan_cache[key] = nil
        return nil
    end

    import_scan_stats.cache_hits = import_scan_stats.cache_hits + 1
    return entry.result
end

local function store_import_scan(key, result)
    import_scan_cache[key] = {
        expires_at_ms = now_ms() + IMPORT_SCAN_CACHE_TTL_MS,
        result = result,
    }
end

local function import_scan_return(result)
    return result[1], result[2], result[3], result[4]
end

function M._clear_import_scan_cache()
    import_scan_cache = {}
    import_scan_stats = {
        attempts = 0,
        cache_hits = 0,
        scans = 0,
        entries = 0,
        files = 0,
        reads = 0,
        last_elapsed_ms = 0,
        last_hit_limit = false,
        last_hit_entry_limit = false,
        last_entries = 0,
        last_max_entries = 0,
        skipped_roots = 0,
        last_skipped_root = nil,
    }
end

--- Clear the short-lived import-scan cache used by project resolution.
function M.clear_import_scan_cache()
    return M._clear_import_scan_cache()
end

function M._import_scan_stats()
    return vim.deepcopy(import_scan_stats)
end

---Return a compact user-facing import-scan stats label.
---@param stats? table Import-scan stats snapshot.
---@return string label Summary suitable for health and reports.
function M.import_scan_stats_summary(stats)
    stats = stats or import_scan_stats
    return ("attempts=%d scans=%d cache_hits=%d files=%d entries=%d reads=%d last=%dms limit=%s entry_limit=%s skipped_roots=%d"):format(
        stats.attempts or 0,
        stats.scans or 0,
        stats.cache_hits or 0,
        stats.files or 0,
        stats.entries or 0,
        stats.reads or 0,
        stats.last_elapsed_ms or 0,
        tostring(stats.last_hit_limit == true),
        tostring(stats.last_hit_entry_limit == true),
        stats.skipped_roots or 0
    )
end

local function import_scan_roots(root, root_source, project_opts)
    local roots = { root }
    if root_source ~= "buffer directory" then
        return roots
    end

    local max_depth = project_opts.import_scan_max_depth or 0
    local current = root
    for _ = 1, max_depth do
        local parent = vim.fs.dirname(current)
        if not parent or parent == current then
            break
        end

        roots[#roots + 1] = util.normalize(parent)
        current = parent
    end

    return roots
end

--- Find a likely main file by scanning bounded local imports that reference a leaf file.
---@param path string Current Typst file opened directly.
---@param root string Current root candidate.
---@param root_source string Source label for the current root candidate.
---@param opts table Plugin configuration containing project import-scan limits.
---@return string|nil main Main file that imports `path`, if a unique fallback is found.
---@return string|nil main_source Source label for the main decision.
---@return string|nil root Root to use with the scanned main.
---@return string|nil root_source Source label for the scanned root.
function M.import_scan_main(path, root, root_source, opts)
    opts = opts or {}
    local project_opts = opts.project or {}
    if not project_opts.import_scan then
        return nil
    end
    import_scan_stats.attempts = import_scan_stats.attempts + 1

    local key = import_scan_key(path, root, root_source, project_opts)
    local cached = cached_import_scan(key)
    if cached then
        return import_scan_return(cached)
    end

    -- Import scanning is a fallback for leaf files opened directly. Keep it
    -- bounded so opening a note in a large workspace cannot turn into an
    -- unbounded recursive search.
    local max_files = project_opts.import_scan_max_files or 200
    local max_entries = project_opts.import_scan_max_entries or 2000
    local max_descendant_depth = project_opts.import_scan_max_descendant_depth
    local skip_dirs = skip_dir_set(project_opts)
    local started_at = uv.hrtime()
    local result = telemetry.time("project.import_scan", function()
        import_scan_stats.scans = import_scan_stats.scans + 1
        for _, scan_root in
            ipairs(import_scan_roots(root, root_source, project_opts))
        do
            local matches = {}
            local candidates, hit_limit, scan_info = collect_typst_files(
                scan_root,
                max_files,
                max_entries,
                skip_dirs,
                max_descendant_depth
            )
            scan_info = scan_info or {}
            import_scan_stats.entries = import_scan_stats.entries
                + (scan_info.entries or 0)
            import_scan_stats.last_entries = scan_info.entries or 0
            import_scan_stats.last_max_entries = max_entries
            import_scan_stats.last_hit_entry_limit = scan_info.hit_entry_limit
                == true
            if scan_info.hit_entry_limit then
                import_scan_stats.last_hit_limit = false
                import_scan_stats.skipped_roots = import_scan_stats.skipped_roots
                    + 1
                import_scan_stats.last_skipped_root = scan_root
                log.add(
                    "warn",
                    "abandoned import scan; root exceeded entry cap",
                    {
                        path = path,
                        root = scan_root,
                        entries = scan_info.entries,
                        limit = max_entries,
                    }
                )
                break
            end
            import_scan_stats.files = import_scan_stats.files + #candidates
            import_scan_stats.last_hit_limit = hit_limit == true
            if hit_limit then
                log.add("info", "import scan reached Typst file limit", {
                    path = path,
                    root = scan_root,
                    limit = max_files,
                    scanned = #candidates,
                })
            end
            for _, candidate in ipairs(candidates) do
                if
                    not util.same_path(candidate, path)
                    and references_file(
                        candidate,
                        path,
                        scan_root,
                        import_scan_stats
                    )
                then
                    matches[#matches + 1] = candidate
                end
            end

            if #matches > 0 then
                table.sort(matches, function(left, right)
                    local left_main = util.basename(left) == "main.typ"
                    local right_main = util.basename(right) == "main.typ"
                    if left_main ~= right_main then
                        return left_main
                    end

                    local left_rel = util.relpath(left, scan_root)
                    local right_rel = util.relpath(right, scan_root)
                    local left_depth = select(2, left_rel:gsub("[/\\]", ""))
                    local right_depth = select(2, right_rel:gsub("[/\\]", ""))
                    if left_depth ~= right_depth then
                        return left_depth < right_depth
                    end

                    return left_rel < right_rel
                end)
                if #matches > 1 then
                    log.add("warn", "import scan found ambiguous Typst mains", {
                        path = path,
                        root = scan_root,
                        candidates = vim.deepcopy(matches),
                    })
                    return { n = 0 }
                end

                return {
                    n = 4,
                    matches[1],
                    "import scan",
                    util.normalize(scan_root),
                    "import scan root",
                }
            end
        end

        return { n = 0 }
    end, {
        path = path,
        root = root,
        max_files = max_files,
        max_entries = max_entries,
    })
    import_scan_stats.last_elapsed_ms =
        math.floor((uv.hrtime() - started_at) / 1000000)
    store_import_scan(key, result)
    return import_scan_return(result)
end

local function common_ancestor(left, right)
    local candidate = util.dirname(left)
    while candidate and candidate ~= "" do
        if M.path_within(right, candidate) then
            return candidate
        end

        local parent = vim.fs.dirname(candidate)
        if not parent or parent == candidate then
            break
        end
        candidate = parent
    end

    return util.dirname(right)
end

--- Widen a heuristic root when an explicit main lives outside it.
---@param root string Current root candidate.
---@param root_source string Source label for the current root candidate.
---@param path string Current buffer path.
---@param main? string Main file resolved for the buffer.
---@param main_source? string Source label for the main decision.
---@return string root Reconciled root path.
---@return string source Source label for the reconciled root.
function M.reconcile_for_main(root, root_source, path, main, main_source)
    if
        root_source ~= "buffer directory"
        or not main
        or M.path_within(main, root)
    then
        return root, root_source
    end

    -- A main discovered from a buffer-local hint can live above or beside the
    -- current file. When the root was only guessed from the buffer directory,
    -- widen it to the common ancestor instead of compiling from the wrong root.
    return common_ancestor(path, main),
        (main_source or "main") .. " common root"
end

return M
