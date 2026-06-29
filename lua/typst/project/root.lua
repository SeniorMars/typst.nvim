local lexical = require("typst.syntax.lexical")
local log = require("typst.core.log")
local util = require("typst.core.util")

local M = {}

local uv = vim.uv or vim.loop

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
        local root = util.resolve_path(configured_root_path, vim.fn.getcwd())
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
---@return string source Human-readable source of the root decision.
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

local function skip_scan_dir(name)
    return name == ".git" or name == "node_modules" or name == ".direnv"
end

local REMAINING_SCAN_DIR_BUDGET = 64

local function scan_has_remaining_candidates(handle, current_dir, queue)
    local pending = vim.deepcopy(queue or {})
    while handle do
        local name, kind = uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if kind == "file" and name:match("%.typ$") then
            return true
        end
        if kind == "directory" and not skip_scan_dir(name) then
            pending[#pending + 1] = util.join(current_dir, name)
        end
    end

    local seen = {}
    local checked = 0
    while #pending > 0 and checked < REMAINING_SCAN_DIR_BUDGET do
        local dir = util.normalize(table.remove(pending, 1))
        if not seen[dir] then
            seen[dir] = true
            checked = checked + 1
            local dir_handle = uv.fs_scandir(dir)
            while dir_handle do
                local name, kind = uv.fs_scandir_next(dir_handle)
                if not name then
                    break
                end
                if kind == "file" and name:match("%.typ$") then
                    return true
                end
                if kind == "directory" and not skip_scan_dir(name) then
                    pending[#pending + 1] = util.join(dir, name)
                end
            end
        end
    end

    return false
end

local function collect_typst_files(root, limit)
    local files = {}
    local queue = { root }
    local seen_dirs = {}
    local hit_limit = false

    while #queue > 0 and #files < limit do
        local dir = table.remove(queue, 1)
        dir = util.normalize(dir)
        if not seen_dirs[dir] then
            seen_dirs[dir] = true
            local handle = uv.fs_scandir(dir)
            while handle and #files < limit do
                local name, kind = uv.fs_scandir_next(handle)
                if not name then
                    break
                end

                local full = util.join(dir, name)
                if kind == "file" and name:match("%.typ$") then
                    files[#files + 1] = util.normalize(full)
                    if #files >= limit then
                        hit_limit =
                            scan_has_remaining_candidates(handle, dir, queue)
                        break
                    end
                elseif kind == "directory" and not skip_scan_dir(name) then
                    queue[#queue + 1] = full
                end
            end
        end
    end

    return files, hit_limit
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

local function references_file(candidate, path, root)
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
    local project_opts = opts.project or {}
    if not project_opts.import_scan then
        return nil
    end

    -- Import scanning is a fallback for leaf files opened directly. Keep it
    -- bounded so opening a note in a large workspace cannot turn into an
    -- unbounded recursive search.
    local max_files = project_opts.import_scan_max_files or 200
    for _, scan_root in
        ipairs(import_scan_roots(root, root_source, project_opts))
    do
        local matches = {}
        local candidates, hit_limit = collect_typst_files(scan_root, max_files)
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
                and references_file(candidate, path, scan_root)
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
                return nil
            end

            return matches[1],
                "import scan",
                util.normalize(scan_root),
                "import scan root"
        end
    end
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
---@param main_source string Source label for the main decision.
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
    return common_ancestor(path, main), main_source .. " common root"
end

return M
