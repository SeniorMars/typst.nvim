local safety = require("typst.workflows.render.safety")
local output_policy = require("typst.core.output_policy")
local util = require("typst.core.util")

local M = {}

local uv = vim.uv or vim.loop

M.DEFAULT_OPTIONS = {
    enabled = true,
    max_entries = 128,
    max_bytes = 64 * 1024 * 1024,
    ttl_ms = 24 * 60 * 60 * 1000,
}

local function json_encode(value)
    if vim.json and vim.json.encode then
        return vim.json.encode(value)
    end
    return vim.fn.json_encode(value)
end

local function json_decode(value)
    if vim.json and vim.json.decode then
        return vim.json.decode(value)
    end
    return vim.fn.json_decode(value)
end

function M.options(render_config, opts)
    opts = opts or {}
    render_config = render_config or {}
    if render_config.cache == false or opts.cache == false then
        return { enabled = false }
    end

    local options = vim.deepcopy(M.DEFAULT_OPTIONS)
    if type(render_config.cache) == "table" then
        options = vim.tbl_extend("force", options, render_config.cache)
    end
    if type(opts.cache) == "table" then
        options = vim.tbl_extend("force", options, opts.cache)
    end
    options.enabled = options.enabled ~= false
    return options
end

function M.file_size(path)
    local stat = type(path) == "string" and uv.fs_stat(path) or nil
    return stat and stat.size or 0
end

function M.entry_expired(entry, options, now)
    return type(options.ttl_ms) == "number"
        and options.ttl_ms > 0
        and entry.cached_at
        and entry.cached_at + options.ttl_ms <= now
end

function M.file_expired(path, options, now)
    if type(options.ttl_ms) ~= "number" or options.ttl_ms <= 0 then
        return false
    end

    local stat = uv.fs_stat(path)
    if not stat or not stat.mtime then
        return false
    end

    local mtime_ms = (stat.mtime.sec or 0) * 1000
        + math.floor((stat.mtime.nsec or 0) / 1000000)
    return mtime_ms + options.ttl_ms <= now
end

function M.manifest_path(dir)
    return util.join(dir, "manifest.json")
end

function M.sentinel_path(dir)
    return safety.sentinel_path(dir)
end

function M.read_manifest(dir)
    local path = M.manifest_path(dir)
    if vim.fn.filereadable(path) ~= 1 then
        return { entries = {} }
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return { entries = {} }
    end

    local decoded_ok, decoded = pcall(json_decode, table.concat(lines, "\n"))
    if decoded_ok and type(decoded) == "table" then
        decoded.entries = decoded.entries or {}
        return decoded
    end
    return { entries = {} }
end

function M.write_manifest(dir, manifest)
    -- A sentinel lets force-clear distinguish a cache directory typst.nvim has
    -- created from an arbitrary user directory configured as render.output_dir.
    safety.mark_owned_cache_dir(dir)
    pcall(
        util.atomic_writefile,
        { json_encode(manifest) },
        M.manifest_path(dir)
    )
end

function M.safe_force_dir(dir)
    return safety.safe_force_dir(dir)
end

local function remove_cache_file(dir, path)
    return output_policy.delete_render_cache_file(dir, path)
end

local function remove_cache_source(dir, path)
    if type(path) ~= "string" or path == "" then
        return true
    end
    if util.path_within(path, dir) and not util.same_path(path, dir) then
        return remove_cache_file(dir, path)
    end
    return true
end

function M.prune_manifest(dir, manifest, options, now)
    local entries = {}
    local total_bytes = 0
    for key, entry in pairs(manifest.entries or {}) do
        local path = entry.path
        local exists = path and vim.fn.filereadable(path) == 1
        local expired = entry.cached_at and M.entry_expired(entry, options, now)
        if not exists or expired then
            remove_cache_file(dir, entry.path)
            remove_cache_source(dir, entry.source_path)
            manifest.entries[key] = nil
        else
            entry.size = entry.size or M.file_size(entry.path)
            total_bytes = total_bytes + (entry.size or 0)
            entries[#entries + 1] = {
                key = key,
                size = entry.size or 0,
                used_at = entry.used_at or entry.cached_at or 0,
            }
        end
    end

    table.sort(entries, function(left, right)
        return left.used_at < right.used_at
    end)
    local count = #entries
    local max_entries = options.max_entries or M.DEFAULT_OPTIONS.max_entries
    local max_bytes = options.max_bytes or M.DEFAULT_OPTIONS.max_bytes
    local index = 1
    while
        index <= #entries
        and (
            (max_entries > 0 and count > max_entries)
            or (max_bytes > 0 and total_bytes > max_bytes)
        )
    do
        local stale = entries[index]
        local entry = manifest.entries[stale.key]
        if entry then
            remove_cache_file(dir, entry.path)
            remove_cache_source(dir, entry.source_path)
            manifest.entries[stale.key] = nil
            count = count - 1
            total_bytes = math.max(0, total_bytes - (stale.size or 0))
        end
        index = index + 1
    end
end

function M.remember_disk(result, options, now)
    if not (result and result.key and result.path) then
        return
    end

    local dir = util.dirname(result.path)
    local manifest = M.read_manifest(dir)
    manifest.entries[result.key] = {
        key = result.key,
        kind = result.kind,
        path = result.path,
        source_path = result.source_path,
        format = result.format,
        page = result.page,
        cached_at = now,
        used_at = now,
        size = M.file_size(result.path),
    }
    M.prune_manifest(dir, manifest, options, now)
    M.write_manifest(dir, manifest)
end

function M.clear_manifest(dir)
    local manifest = M.read_manifest(dir)
    local deleted = 0
    local failed = {}
    local skipped = {}

    for key, entry in pairs(manifest.entries or {}) do
        local entry_failed = false
        for _, field in ipairs({ "path", "source_path" }) do
            local path = entry[field]
            if path then
                local ok, err
                if field == "source_path" then
                    ok, err = remove_cache_source(dir, path)
                else
                    ok, err = remove_cache_file(dir, path)
                end
                if ok then
                    if
                        field ~= "source_path"
                        or (
                            util.path_within(path, dir)
                            and not util.same_path(path, dir)
                        )
                    then
                        deleted = deleted + 1
                    end
                elseif err == "outside_cache" then
                    skipped[#skipped + 1] = path
                else
                    failed[#failed + 1] = {
                        path = path,
                        error = err,
                    }
                    entry_failed = true
                end
            end
        end
        if not entry_failed then
            manifest.entries[key] = nil
        end
    end

    if next(manifest.entries or {}) then
        M.write_manifest(dir, manifest)
    else
        util.delete_checked(M.manifest_path(dir))
    end

    return deleted, failed, skipped
end

return M
