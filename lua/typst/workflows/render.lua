local output_policy = require("typst.core.output_policy")
local planner = require("typst.workflows.render.planner")
local render_cache = require("typst.workflows.render.cache")
local render_display = require("typst.workflows.render.display")
local render_runner = require("typst.workflows.render.runner")
local util = require("typst.core.util")
local windows = require("typst.core.windows")

local M = {}

-- Render previews for fragments, equations, pages, and image-at-cursor display.
--
-- This facade keeps user-facing render APIs stable. Planning lives in
-- render.planner, built-in Typst process execution lives in render.runner, and
-- provider/display/cache details stay in their narrower modules.

local cache = {}

local image_extensions = {
    gif = true,
    jpeg = true,
    jpg = true,
    png = true,
    svg = true,
    webp = true,
}

local notify_user = require("typst.core.notify").user

local function delete_cache_source(dir, source_path)
    if
        type(source_path) == "string"
        and source_path ~= ""
        and not planner.virtual_source_path(source_path)
        and util.path_within(source_path, dir)
        and not util.same_path(source_path, dir)
    then
        return output_policy.delete_render_cache_file(dir, source_path)
    end
    return true
end

local function cached_result(project, kind, opts)
    local options = planner.cache_options(opts)
    if not options.enabled or options.max_entries == 0 then
        return nil
    end

    local key, path, source_path, _, path_error =
        planner.output_path(project, kind, opts)
    if path_error or not path then
        return nil
    end

    local entry = cache[key]
    if entry and entry.path == path and vim.fn.filereadable(path) == 1 then
        local now = planner.now_ms()
        if render_cache.entry_expired(entry, options, now) then
            local dir = util.dirname(entry.path)
            output_policy.delete_render_cache_file(dir, entry.path)
            delete_cache_source(dir, entry.source_path)
            cache[key] = nil
            return nil
        end
        entry.used_at = now
        local result = vim.deepcopy(entry)
        result.cached = true
        return result
    end

    local now = planner.now_ms()
    local dir = util.dirname(path)
    local manifest = render_cache.read_manifest(dir)
    local disk_entry = manifest.entries and manifest.entries[key] or nil
    if disk_entry and disk_entry.path == path then
        if
            vim.fn.filereadable(disk_entry.path) ~= 1
            or render_cache.entry_expired(disk_entry, options, now)
        then
            output_policy.delete_render_cache_file(dir, disk_entry.path)
            delete_cache_source(dir, disk_entry.source_path)
            manifest.entries[key] = nil
            render_cache.write_manifest(dir, manifest)
            return nil
        end

        disk_entry.used_at = now
        render_cache.write_manifest(dir, manifest)
        cache[key] = vim.tbl_extend("force", vim.deepcopy(disk_entry), {
            ok = true,
            cached = false,
            used_at = now,
        })
        local result = vim.deepcopy(cache[key])
        result.cached = true
        result.kind = result.kind or kind
        result.source_path = result.source_path or source_path
        result.format = result.format
            or opts.format
            or planner.render_config(opts).output_format
            or "svg"
        return result
    end

    if vim.fn.filereadable(path) == 1 then
        -- Deterministic render paths are not authoritative by themselves. A
        -- disk hit must be backed by the manifest written when typst.nvim
        -- successfully remembered the render result.
        output_policy.delete_render_cache_file(dir, path)
        delete_cache_source(dir, source_path)
    end
end

local function evict_cache(options)
    local entries = {}
    local total_bytes = 0
    for key, entry in pairs(cache) do
        entry.size = entry.size or render_cache.file_size(entry.path)
        total_bytes = total_bytes + (entry.size or 0)
        entries[#entries + 1] = {
            key = key,
            size = entry.size or 0,
            used_at = entry.used_at or entry.cached_at or 0,
        }
    end

    table.sort(entries, function(left, right)
        return left.used_at < right.used_at
    end)
    local count = #entries
    local max_entries = options.max_entries
        or render_cache.DEFAULT_OPTIONS.max_entries
    local max_bytes = options.max_bytes
        or render_cache.DEFAULT_OPTIONS.max_bytes
    local index = 1
    while
        index <= #entries
        and (
            (max_entries > 0 and count > max_entries)
            or (max_bytes > 0 and total_bytes > max_bytes)
        )
    do
        local stale = entries[index]
        local entry = cache[stale.key]
        if entry then
            local dir = util.dirname(entry.path)
            output_policy.delete_render_cache_file(dir, entry.path)
            delete_cache_source(dir, entry.source_path)
            cache[stale.key] = nil
            count = count - 1
            total_bytes = math.max(0, total_bytes - (stale.size or 0))
        end
        index = index + 1
    end
end

local function remember(result, opts)
    if result and result.key then
        local options = planner.cache_options(opts)
        if not options.enabled or options.max_entries == 0 then
            return
        end

        local now = planner.now_ms()
        cache[result.key] = {
            ok = result.ok,
            key = result.key,
            kind = result.kind,
            path = result.path,
            source_path = result.source_path,
            format = result.format,
            page = result.page,
            cached = false,
            cached_at = now,
            used_at = now,
            size = render_cache.file_size(result.path),
        }
        result.remembered = true
        evict_cache(options)
        render_cache.remember_disk(result, options, now)
    end
end

local cache_api = {
    cached_result = cached_result,
    remember = remember,
}

local function cursor_for_buffer(bufnr)
    local winid = windows.for_buffer(bufnr)
    if not winid then
        return nil
    end
    return vim.api.nvim_win_get_cursor(winid)
end

local function selected_lines(opts)
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local cursor = cursor_for_buffer(bufnr)
    local line1 = tonumber(opts.line1) or (cursor and cursor[1]) or 1
    local line2 = tonumber(opts.line2) or line1
    line1 = math.max(1, math.min(line_count, line1))
    line2 = math.max(1, math.min(line_count, line2))
    if line2 < line1 then
        line1, line2 = line2, line1
    end
    return vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false),
        { line1, line2 }
end

local function word_at_cursor(opts)
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local cursor = cursor_for_buffer(bufnr)
    if not cursor then
        return ""
    end
    local line = vim.api.nvim_buf_get_lines(
        bufnr,
        cursor[1] - 1,
        cursor[1],
        false
    )[1] or ""
    local col = cursor[2] + 1
    local start_col = col
    while
        start_col > 1
        and line:sub(start_col - 1, start_col - 1):match("[%w_%-:]")
    do
        start_col = start_col - 1
    end
    local end_col = col
    while end_col <= #line and line:sub(end_col, end_col):match("[%w_%-:]") do
        end_col = end_col + 1
    end
    return line:sub(start_col, end_col - 1)
end

--- Render a selected Typst fragment into a temporary preview artifact.
---@param project table Project state supplying root/config context.
---@param opts? table Render options, including range, format, cache, and display provider.
---@param callback? fun(result:table, project:table) Callback invoked with render result.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table result Render result or pending operation handle.
function M.fragment(project, opts, callback, notify)
    opts = opts or {}
    local source = opts.source
    local range
    if not source or source == "" then
        local lines
        lines, range = selected_lines(opts)
        source = table.concat(lines, "\n")
    end
    if source == "" then
        return {
            ok = false,
            reason = "empty_source",
            message = "No Typst source was selected",
        }
    end

    return render_runner.source(
        project,
        "fragment",
        source,
        vim.tbl_extend("force", opts, { range = range }),
        callback,
        notify,
        cache_api
    )
end

--- Render the equation under the cursor into a temporary preview artifact.
---@param project table Project state supplying root/config context.
---@param opts? table Render options, including cursor location, format, cache, and display provider.
---@param callback? fun(result:table, project:table) Callback invoked with render result.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table result Render result or pending operation handle.
function M.equation(project, opts, callback, notify)
    opts = opts or {}
    local expression = vim.trim(opts.expression or opts.args or "")
    if expression == "" then
        local lines = selected_lines(opts)
        expression = vim.trim(table.concat(lines, "\n"))
    end
    if expression == "" then
        expression = word_at_cursor(opts)
    end
    if expression == "" then
        return {
            ok = false,
            reason = "empty_expression",
            message = "No Typst equation expression was provided",
        }
    end

    local source = table.concat({
        "#set page(width: auto, height: auto, margin: 0pt)",
        "$ " .. expression .. " $",
    }, "\n")
    return render_runner.source(
        project,
        "equation",
        source,
        opts,
        callback,
        notify,
        cache_api
    )
end

--- Render the current page or main document into a preview artifact.
---@param project table Project state whose main document should be rendered.
---@param opts? table Render options, including page, format, cache, and display provider.
---@param callback? fun(result:table, project:table) Callback invoked with render result.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table result Render result or pending operation handle.
function M.page(project, opts, callback, notify)
    return render_runner.page(project, opts, callback, notify, cache_api)
end

local function quoted_path_at_cursor(opts)
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local cursor = cursor_for_buffer(bufnr)
    local row = (opts.pos and opts.pos[1]) or (cursor and cursor[1] - 1) or 0
    local col = (opts.pos and opts.pos[2]) or (cursor and cursor[2]) or 0
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""

    local index = 1
    while index <= #line do
        local start_col, _, quote = line:find("([\"'])", index)
        if not start_col then
            break
        end

        local close_col = start_col + 1
        while close_col <= #line do
            if
                line:sub(close_col, close_col) == quote
                and line:sub(close_col - 1, close_col - 1) ~= "\\"
            then
                local value = line:sub(start_col + 1, close_col - 1)
                if col + 1 >= start_col and col + 1 <= close_col then
                    return value
                end
                break
            end
            close_col = close_col + 1
        end

        index = math.max(close_col + 1, start_col + 1)
    end

    return line:match("[\"']([^\"']+%.[%w]+)[\"']")
end

local function resolve_image_path(project, opts)
    local path = opts.path or quoted_path_at_cursor(opts)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    local ext = (path:match("%.([%w]+)$") or ""):lower()
    if not image_extensions[ext] then
        return nil
    end

    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local buffer_name = vim.api.nvim_buf_get_name(bufnr)
    local base = buffer_name ~= "" and util.dirname(buffer_name) or project.root
    return util.resolve_path(path, base), ext
end

--- Open or display an image path resolved from the Typst source context.
---@param project table Project state used to resolve relative image paths.
---@param opts? table Image options, including path, cursor query, and display provider.
---@param _? any Unused callback slot kept for runtime API symmetry.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table result Image display/open result.
function M.image(project, opts, _, notify)
    opts = opts or {}
    local path, ext = resolve_image_path(project, opts)
    if not path then
        return {
            ok = false,
            reason = "missing_image",
            message = "No image path was found under the cursor",
        }
    end
    if vim.fn.filereadable(path) ~= 1 then
        return {
            ok = false,
            reason = "unreadable_image",
            path = path,
            message = "Image path is not readable",
        }
    end

    local result = {
        ok = true,
        cached = true,
        kind = "image",
        path = path,
        format = ext,
        dimensions = render_display.image_dimensions(path, ext),
    }
    return render_display.display(result, opts, notify)
end

--- Clear in-memory and disk-backed render cache entries.
---@param opts? table Cache clearing controls.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table result Count of render cache entries removed.
function M.cache_clear(opts, notify)
    opts = opts or {}
    local root = opts.root
        or (type(opts.project) == "table" and opts.project.root)
        or vim.fn.getcwd()
    local dir = planner.cache_dir(opts, root)
    cache = {}
    if vim.fn.isdirectory(dir) == 1 then
        if opts.force == true then
            local ok, err = output_policy.delete_render_cache_dir(dir)
            if not ok then
                if
                    type(err) == "table"
                    and err.reason == "unsafe_cache_dir"
                then
                    return {
                        ok = false,
                        reason = "unsafe_cache_dir",
                        message = err.message,
                        path = dir,
                    }
                end
                return {
                    ok = false,
                    reason = "delete_failed",
                    message = type(err) == "table"
                            and (err.message or err.reason)
                        or tostring(err),
                    path = dir,
                }
            end
            notify_user(notify, "Cleared Typst render cache")
            return {
                ok = true,
                path = dir,
                forced = true,
            }
        end

        local deleted, failed, skipped = render_cache.clear_manifest(dir)
        if #failed > 0 then
            return {
                ok = false,
                reason = "delete_failed",
                message = "Failed to delete one or more render cache files",
                path = dir,
                deleted = deleted,
                failed = failed,
                skipped = skipped,
            }
        end
        if #skipped > 0 then
            notify_user(
                notify,
                "Skipped render cache entries outside the cache directory",
                vim.log.levels.WARN
            )
            return {
                ok = true,
                path = dir,
                deleted = deleted,
                skipped = skipped,
            }
        end
        notify_user(notify, "Cleared Typst render cache")
        return {
            ok = true,
            path = dir,
            deleted = deleted,
        }
    end
    notify_user(notify, "Cleared Typst render cache")
    return {
        ok = true,
        path = dir,
        deleted = 0,
    }
end

--- Return a copy of the render cache for diagnostics/tests.
---@return table cache Snapshot of cached render entries.
function M.cache_entries()
    return vim.deepcopy(cache)
end

M._cache_key_for_tests = planner.cache_key

return M
