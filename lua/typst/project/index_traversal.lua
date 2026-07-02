local bibliography_index = require("typst.bibliography.index")
local aggregate = require("typst.project.index.aggregate")
local index_cache = require("typst.project.index.cache")
local index_files = require("typst.project.index.files")
local log = require("typst.core.log")
local scanner = require("typst.project.index.scanner")
local util = require("typst.core.util")

local M = {}
local uv = vim.uv or vim.loop
local DEFAULT_STATIC_INDEX_FILE_BYTES = 1024 * 1024

local file_version = index_files.file_version
local initial_files = index_files.initial_files
local sorted_keys = index_cache.sorted_keys

-- Traversal owns the project file graph seen by the static index. It starts
-- from known project files, follows local imports/includes, and adds referenced
-- bibliography files as a separate cached input set.

local function add_unique(list, seen, key, item)
    if not key or seen[key] then
        return
    end

    seen[key] = true
    list[#list + 1] = item
end

local function source_location(path, row, col)
    return {
        path = path,
        lnum = row,
        col = col or 1,
    }
end

local file_record_categories = {
    "headings",
    "labels",
    "references",
    "citations",
    "imports",
    "imported_bindings",
    "wildcard_imports",
    "module_aliases",
    "definitions",
    "definitions_by_file",
    "glossary_entries",
    "todos",
    "figures",
    "tables",
    "equations",
    "paths",
    "bibliography_paths",
}

local function file_cache_entry(version, record, cache_version)
    local entry = {
        path = record.path,
        key = util.path_key(record.path),
        version = version,
        cache_version = cache_version or version,
        record = record,
        graph = record.imports or {},
    }
    local data = record.data or {}
    for _, category in ipairs(file_record_categories) do
        entry[category] = data[category] or {}
    end
    return entry
end

local function empty_file_record(project, path)
    return {
        path = path,
        data = aggregate.empty_collected(project),
        imports = {},
    }
end

local function index_config()
    local ok, config = pcall(require, "typst.config")
    if not ok then
        return {}, 0
    end
    local cfg = config.unsafe_get()
    return ((cfg.project or {}).index or {}), config.generation()
end

local function traversal_config()
    local index, generation = index_config()
    local max_bytes = tonumber(index.max_file_bytes)
    if max_bytes == nil then
        max_bytes = DEFAULT_STATIC_INDEX_FILE_BYTES
    end
    return {
        max_file_bytes = max_bytes,
        large_file_policy = index.large_file_policy or "skip",
        config_generation = generation or 0,
    }
end

local function file_cache_policy_signature(config)
    config = config or traversal_config()
    return table.concat({
        "config_generation=" .. tostring(config.config_generation or 0),
        "max_file_bytes=" .. tostring(config.max_file_bytes),
        "large_file_policy=" .. tostring(config.large_file_policy),
    }, "\n")
end

local function cache_version(project, path, config)
    return file_version(project, path)
        .. "\n"
        .. file_cache_policy_signature(config)
end

local function should_skip_large_file(project, path, config)
    config = config or traversal_config()
    local bufnr = index_files.buffer_for_file(project, path)
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
        return false, nil, config.max_file_bytes, config.large_file_policy
    end

    local max_bytes = config.max_file_bytes
    local policy = config.large_file_policy
    if max_bytes <= 0 or policy == "scan" then
        return false, nil, max_bytes, policy
    end

    local stat = uv.fs_stat(path)
    return stat and type(stat.size) == "number" and stat.size > max_bytes,
        stat,
        max_bytes,
        policy
end

local function cached_file_record(project, path, config)
    local project_index = index_cache.ensure(project)
    config = config or traversal_config()
    local version = file_version(project, path)
    local expected_cache_version = cache_version(project, path, config)
    local key = util.path_key(path)
    local cached = project_index.files[key]
    if
        cached
        and (cached.cache_version or cached.version)
            == expected_cache_version
    then
        if not cached.headings and cached.record then
            cached = file_cache_entry(
                cached.version or version,
                cached.record,
                cached.cache_version or expected_cache_version
            )
        end
        project_index.files[key] = cached
        index_cache.record_hit(project_index, "file_hits")
        project_index.graph[key] =
            vim.deepcopy((cached.record or {}).imports or {})
        return cached.record
    end

    index_cache.record_hit(project_index, "file_misses")
    local skip_large, stat, max_bytes, policy =
        should_skip_large_file(project, path, config)
    local record
    if skip_large then
        log.add("warn", "skipped large Typst index file", {
            path = path,
            size = stat and stat.size or nil,
            limit = max_bytes,
            policy = policy,
        })
        if policy == "headings-only" then
            record = scanner.scan_file_record_headings_only(project, path)
        else
            record = empty_file_record(project, path)
        end
    else
        record = scanner.scan_file_record(project, path)
    end
    local entry = file_cache_entry(version, record, expected_cache_version)
    project_index.files[key] = entry
    project_index.graph[key] = vim.deepcopy(record.imports or {})
    return record
end

local bibliography_record_categories = {
    "citations",
    "all_citations",
}

local function bibliography_cache_entry(version, record)
    local entry = {
        path = record.path,
        key = util.path_key(record.path),
        version = version,
        record = record,
    }
    local data = record.data or {}
    for _, category in ipairs(bibliography_record_categories) do
        entry[category] = data[category] or {}
    end
    return entry
end

local function cached_bibliography_record(project, path)
    local project_index = index_cache.ensure(project)
    local version = file_version(project, path)
    local key = util.path_key(path)
    local cached = project_index.bibliographies[key]
    if cached and cached.version == version then
        if not cached.citations and cached.record then
            cached = bibliography_cache_entry(version, cached.record)
            project_index.bibliographies[key] = cached
        end
        index_cache.record_hit(project_index, "bibliography_hits")
        return cached.record
    end

    index_cache.record_hit(project_index, "bibliography_misses")
    local record = bibliography_index.scan(path, { project = project })
    project_index.bibliographies[key] =
        bibliography_cache_entry(version, record)
    return record
end

local function collect_bibliography_records(project, bibliography_paths)
    local records = {}
    for path in pairs(bibliography_paths) do
        if vim.fn.filereadable(path) == 1 then
            records[path] = cached_bibliography_record(project, path)
        end
    end
    return records
end

--- Merge parsed bibliography records into an index aggregate.
---@param out table Aggregate output table to mutate.
---@param seen table Per-category seen-key tables.
---@param records table Bibliography records keyed by path.
function M.merge_bibliography_records(out, seen, records)
    for _, path in ipairs(sorted_keys(records)) do
        aggregate.merge(out, seen, records[path].data)
    end
end

--- Traverse project source and bibliography files for cached index records.
---@param project table Project state to traverse.
---@return table traversal Traversal records, visited files, and bibliography paths.
function M.collect(project)
    local queue, queued = initial_files(project)
    local initial_paths = vim.deepcopy(queue)
    local visited = {}
    local records = {}
    local bibliography_paths = {}
    local config = traversal_config()

    local index = 1
    while index <= #queue do
        local path = queue[index]
        visited[util.path_key(path)] = path
        local record = cached_file_record(project, path, config)
        records[#records + 1] = record

        for bibliography_path in pairs(record.data.bibliography_paths or {}) do
            bibliography_paths[bibliography_path] = true
        end

        for _, imported_path in ipairs(record.imports or {}) do
            local imported_key = util.path_key(imported_path)
            if
                vim.fn.filereadable(imported_path) == 1
                and not queued[imported_key]
            then
                queued[imported_key] = true
                queue[#queue + 1] = imported_path
            end
        end

        index = index + 1
    end

    return {
        initial_paths = initial_paths,
        records = records,
        visited = visited,
        bibliography_paths = bibliography_paths,
        bibliography_records = collect_bibliography_records(
            project,
            bibliography_paths
        ),
    }
end

--- Build a deterministic signature for a traversal result.
---@param project table Project state whose index cache supplies file versions.
---@param traversal table Traversal result returned by `collect`.
---@return string signature Cache signature for aggregate reuse.
function M.signature(project, traversal)
    local project_index = index_cache.ensure(project)
    local parts = {
        "root",
        project.root or "",
        "main",
        project.main or "",
        "initial",
    }

    table.sort(traversal.initial_paths)
    for _, path in ipairs(traversal.initial_paths) do
        parts[#parts + 1] = path
    end

    parts[#parts + 1] = "files"
    for _, key in ipairs(sorted_keys(traversal.visited)) do
        local path = traversal.visited[key] or key
        local entry = project_index.files[key]
        parts[#parts + 1] = ("%s=%s"):format(
            path,
            entry and (entry.cache_version or entry.version) or "missing"
        )
    end

    parts[#parts + 1] = "bibliographies"
    for _, path in ipairs(sorted_keys(traversal.bibliography_paths)) do
        local entry = project_index.bibliographies[util.path_key(path)]
        parts[#parts + 1] = ("%s=%s"):format(
            path,
            entry and entry.version or "missing"
        )
    end

    return table.concat(parts, "\n")
end

--- Return the file paths that should be watched for traversal freshness.
---@param traversal table Traversal result returned by `collect`.
---@return table paths Paths keyed by normalized path.
function M.watch_paths(traversal)
    local paths = {}
    for key, path in pairs((traversal and traversal.visited) or {}) do
        paths[key] = type(path) == "string" and path or key
    end
    for path in pairs((traversal and traversal.bibliography_paths) or {}) do
        paths[util.path_key(path)] = path
    end
    return paths
end

--- Add project file path items to an index aggregate.
---@param project table Project state whose files are added.
---@param out table Aggregate output table to mutate.
---@param seen table Per-category seen-key tables.
function M.add_project_files(project, out, seen)
    local files = initial_files(project)
    for _, path in ipairs(files) do
        local rel = util.relpath(path, project.root)
        add_unique(out.paths, seen.paths, rel, {
            path = path,
            word = rel,
            kind = "path",
            path_kind = "project",
            source = source_location(path, 1, 1),
        })
    end
end

--- Prune file and bibliography cache records no longer in traversal output.
---@param project table Project state whose index cache is pruned.
---@param visited table Files visited by the latest traversal.
---@param bibliography_paths table Bibliography paths used by the latest traversal.
function M.prune(project, visited, bibliography_paths)
    local project_index = index_cache.ensure(project)

    -- Prune cache records after every traversal so files removed from the import
    -- graph stop contributing labels, citations, headings, and diagnostics.
    local visited_keys = {}
    for key, path in pairs(visited or {}) do
        visited_keys[key] = true
        if type(path) == "string" then
            visited_keys[util.path_key(path)] = true
        end
    end

    local bibliography_keys = {}
    for path in pairs(bibliography_paths or {}) do
        bibliography_keys[util.path_key(path)] = true
    end

    for key in pairs(project_index.files) do
        if not visited_keys[key] then
            project_index.files[key] = nil
            project_index.graph[key] = nil
        end
    end

    for key in pairs(project_index.bibliographies) do
        if not bibliography_keys[key] then
            project_index.bibliographies[key] = nil
        end
    end
end

return M
