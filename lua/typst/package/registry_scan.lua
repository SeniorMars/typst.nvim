local manifest_reader = require("typst.package.manifest")
local resources = require("typst.package.resources")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local M = {}

local uv = vim.uv or vim.loop

local package_resource_file = resources.package_resource_file
local sanitize_resource_hints = resources.sanitize_resource_hints
local sorted_directories

-- Package cache scans assume Typst's cache layout:
--   root/namespace/package/version/typst.toml
-- Keep scans shallow and deterministic so completion can diff signatures and
-- refresh incrementally without walking package contents.

local function add_cached_package(
    records,
    seen,
    cache_root,
    namespace,
    package_name,
    version
)
    local dir =
        util.canonical(util.join(cache_root, namespace, package_name, version))
    local manifest_path = util.canonical(util.join(dir, "typst.toml"))
    if vim.fn.filereadable(manifest_path) ~= 1 then
        return
    end

    local manifest = manifest_reader.read(manifest_path)
    local name = manifest.name or package_name
    local package_version = manifest.version or version
    local spec = ("@%s/%s:%s"):format(namespace, name, package_version)
    if seen[spec] then
        return
    end

    local entrypoint_file, entrypoint_error =
        package_resource_file(dir, manifest.entrypoint or "lib.typ", {
            outside_reason = "entrypoint_outside_package",
        })
    local resource_hints, resource_hint_errors =
        sanitize_resource_hints(dir, manifest.typst_docs)

    seen[spec] = true
    records[#records + 1] = {
        namespace = namespace,
        name = name,
        version = package_version,
        spec = spec,
        root = dir,
        cache_root = cache_root,
        manifest = manifest_path,
        description = manifest.description,
        entrypoint = entrypoint_file and entrypoint_file.relative or nil,
        entrypoint_error = entrypoint_error ~= "invalid_path"
                and entrypoint_error
            or nil,
        compiler = manifest.compiler,
        license = manifest.license,
        authors = manifest.authors,
        keywords = manifest.keywords,
        categories = manifest.categories,
        resource_hints = resource_hints,
        resource_hint_errors = next(resource_hint_errors)
                and resource_hint_errors
            or nil,
        template = manifest.template,
        is_template = type(manifest.template) == "table",
    }
end

local function stat_signature(path, rel)
    local stat = uv.fs_stat(path)
    if not stat then
        return ("%s:missing"):format(rel)
    end

    return ("%s:%s:%d:%d:%d"):format(
        rel,
        stat.type or "",
        stat.size or 0,
        (stat.mtime and stat.mtime.sec) or 0,
        (stat.mtime and stat.mtime.nsec) or 0
    )
end

local function package_root_signature(root)
    root = util.canonical(root)
    local root_stat = uv.fs_stat(root)
    if not root_stat then
        return ("%s:missing"):format(root)
    end

    local parts = {}
    local function walk(dir, rel, depth)
        parts[#parts + 1] = stat_signature(dir, rel)
        if depth >= 2 then
            -- Version directory mtimes are enough to detect package installs or
            -- removals; deep package files are scanned only when a package is
            -- opened or completed.
            return
        end

        local scan = uv.fs_scandir(dir)
        if not scan then
            return
        end

        local entries = {}
        while true do
            local name, kind = uv.fs_scandir_next(scan)
            if not name then
                break
            end
            if kind == "directory" then
                entries[#entries + 1] = name
            end
        end

        table.sort(entries)
        for _, name in ipairs(entries) do
            walk(
                util.join(dir, name),
                rel == "." and name or util.join(rel, name),
                depth + 1
            )
        end
    end

    walk(root, ".", 0)
    return table.concat(parts, "\n")
end

function M.root_signatures(roots)
    local signatures = {}
    for _, root in ipairs(roots or {}) do
        signatures[root] = package_root_signature(root)
    end
    return signatures
end

function M.watch_dirs(roots)
    local dirs = {}
    local seen = {}

    local function add(path, expected_type)
        path = util.normalize(path)
        if not path or seen[path] then
            return false
        end

        local stat = uv.fs_stat(path)
        if not stat or (expected_type and stat.type ~= expected_type) then
            return false
        end

        seen[path] = true
        dirs[#dirs + 1] = path
        return true
    end

    local function walk(dir, depth)
        if not add(dir, "directory") then
            return
        end

        add(util.join(dir, "typst.toml"), "file")

        if depth >= 3 then
            return
        end

        for _, name in ipairs(sorted_directories(dir)) do
            walk(util.join(dir, name), depth + 1)
        end
    end

    for _, root in ipairs(roots or {}) do
        walk(root, 0)
    end

    table.sort(dirs)
    return dirs
end

function sorted_directories(path)
    local scan = uv.fs_scandir(path)
    if not scan then
        return {}
    end

    local entries = {}
    while true do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then
            break
        end
        if kind == "directory" then
            entries[#entries + 1] = name
        end
    end

    table.sort(entries)
    return entries
end

local function scan_cached_package_root(root, records, seen)
    for _, namespace in ipairs(sorted_directories(root)) do
        local namespace_dir = util.join(root, namespace)
        for _, package_name in ipairs(sorted_directories(namespace_dir)) do
            local package_dir_path = util.join(namespace_dir, package_name)
            for _, version in ipairs(sorted_directories(package_dir_path)) do
                add_cached_package(
                    records,
                    seen,
                    root,
                    namespace,
                    package_name,
                    version
                )
            end
        end
    end
end

function M.scan_roots(roots)
    local records = {}
    local seen = {}
    for _, root in ipairs(roots or {}) do
        scan_cached_package_root(root, records, seen)
    end
    return records
end

local function new_scan_state(roots)
    return {
        roots = roots or {},
        root_index = 1,
        records = {},
        seen = {},
        namespaces = nil,
        namespace_index = 1,
        package_names = nil,
        package_index = 1,
        versions = nil,
        version_index = 1,
    }
end

local function clear_package_state(state)
    state.versions = nil
    state.version_index = 1
end

local function clear_namespace_state(state)
    state.package_names = nil
    state.package_index = 1
    clear_package_state(state)
end

local function clear_root_state(state)
    state.namespaces = nil
    state.namespace_index = 1
    clear_namespace_state(state)
end

local function advance_root(state)
    state.root_index = state.root_index + 1
    clear_root_state(state)
end

local function scan_step(state, budget)
    budget = math.max(1, tonumber(budget) or 64)
    local processed = 0

    while processed < budget do
        local root = state.roots[state.root_index]
        if not root then
            return true
        end

        if not state.namespaces then
            state.namespaces = sorted_directories(root)
            state.namespace_index = 1
        end

        local namespace = state.namespaces[state.namespace_index]
        if not namespace then
            advance_root(state)
        else
            local namespace_dir = util.join(root, namespace)
            if not state.package_names then
                state.package_names = sorted_directories(namespace_dir)
                state.package_index = 1
            end

            local package_name = state.package_names[state.package_index]
            if not package_name then
                state.namespace_index = state.namespace_index + 1
                clear_namespace_state(state)
            else
                local package_dir_path = util.join(namespace_dir, package_name)
                if not state.versions then
                    state.versions = sorted_directories(package_dir_path)
                    state.version_index = 1
                end

                local version = state.versions[state.version_index]
                if not version then
                    state.package_index = state.package_index + 1
                    clear_package_state(state)
                else
                    add_cached_package(
                        state.records,
                        state.seen,
                        root,
                        namespace,
                        package_name,
                        version
                    )
                    state.version_index = state.version_index + 1
                    processed = processed + 1
                end
            end
        end
    end

    return false
end

function M.scan_roots_async(roots, opts, callback)
    opts = opts or {}
    local state = new_scan_state(roots)
    local budget = opts.budget or opts.batch_size or 64
    local delay_ms = opts.delay_ms or 0

    local function tick()
        local started = telemetry.start()
        local ok, done_or_err = pcall(scan_step, state, budget)
        telemetry.finish("package.scan_batch", started, {
            budget = budget,
            done = ok and done_or_err == true,
            ok = ok,
            records = #state.records,
        })
        if not ok then
            callback(nil, done_or_err)
            return
        end

        if done_or_err then
            callback(state.records)
            return
        end

        -- Yield between batches so package completion prewarm cannot monopolize
        -- the Neovim event loop on a large cache.
        vim.defer_fn(tick, delay_ms)
    end

    vim.schedule(tick)
    return state
end

return M
