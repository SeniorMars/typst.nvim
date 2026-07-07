local config = require("typst.config")
local async = require("typst.core.async")
local events = require("typst.core.events")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local output_path_util = require("typst.compiler.output_path")
local output_policy = require("typst.core.output_policy")
local output_ownership = require("typst.resources.outputs")
local providers = require("typst.integrations.providers")
local resource_manager = require("typst.runtime.resource_manager")
local graph_service = require("typst.project.services.graph")
local index_service = require("typst.project.services.index")
local render_cache = require("typst.workflows.render.cache")
local render_display = require("typst.workflows.render.display")
local render_provider = require("typst.workflows.render.provider")
local util = require("typst.core.util")
local windows = require("typst.core.windows")

local M = {}

-- Render previews for fragments, equations, pages, and image-at-cursor display.
--
-- Render results are cacheable but not authoritative compiler state. Per-kind
-- generations and path leases keep overlapping previews from publishing stale
-- output or colliding with compile/export jobs.
local uv = vim.uv or vim.loop

local cache = {}

local image_extensions = {
    gif = true,
    jpeg = true,
    jpg = true,
    png = true,
    svg = true,
    webp = true,
}

local function start_render_generation(project, kind)
    -- Generations are per render kind: a slow equation preview must not
    -- invalidate an unrelated page render, but a newer equation request wins.
    project.render_generations = project.render_generations or {}
    project.render_generations[kind] = (project.render_generations[kind] or 0)
        + 1
    return project.render_generations[kind]
end

local function rollback_render_generation(project, kind, generation)
    if
        generation
        and project.render_generations
        and project.render_generations[kind] == generation
    then
        project.render_generations[kind] = generation - 1
    end
end

local function token_stale_result(token, kind, generation)
    if not token then
        return nil
    end
    local valid, reason = resource_manager.valid_token(token)
    if valid then
        return nil
    end
    return {
        ok = false,
        pending = false,
        stale = true,
        reason = reason or "stale_result",
        kind = kind,
        generation = generation,
        message = reason == "reset"
                and "A render result was ignored after typst.nvim reset"
            or "A render result was ignored after the project changed",
    }
end

local function render_generation_stale(project, kind, generation)
    return generation ~= nil
        and project.render_generations
        and project.render_generations[kind] ~= generation
end

local function render_stale(project, kind, generation, token)
    return token_stale_result(token, kind, generation) ~= nil
        or render_generation_stale(project, kind, generation)
end

local function stale_render_result(kind, generation, token)
    local token_result = token_stale_result(token, kind, generation)
    if token_result then
        return token_result
    end
    return {
        ok = false,
        stale = true,
        reason = "stale_result",
        kind = kind,
        generation = generation,
        message = "A newer render request finished first",
    }
end

local notify_user = require("typst.core.notify").user

local function render_config(opts)
    opts = opts or {}
    return vim.tbl_extend("force", config.unsafe_get().render or {}, opts or {})
end

local function now_ms()
    if uv and type(uv.now) == "function" then
        return uv.now()
    end
    return math.floor(vim.loop.hrtime() / 1000000)
end

local function cache_options(opts)
    opts = opts or {}
    return render_cache.options(render_config(opts), opts)
end

local function hash_key(parts)
    local keys = vim.tbl_keys(parts)
    table.sort(keys)
    local encoded = {}
    for _, key in ipairs(keys) do
        local part = parts[key]
        if type(part) == "table" then
            part = vim.inspect(part)
        end
        encoded[#encoded + 1] = tostring(key) .. "=" .. tostring(part or "")
    end
    local text = table.concat(encoded, "\n\31\n")

    if vim.fn.exists("*sha256") == 1 then
        return vim.fn.sha256(text)
    end

    local hash = 5381
    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % 4294967296
    end
    return ("%08x"):format(hash)
end

local function cache_key(project, kind, opts)
    return hash_key({
        document = opts.document_signature,
        executable = config.unsafe_get().executable,
        extra_args = opts.extra_args,
        format = opts.format,
        kind = kind,
        main = project.main,
        page = opts.page,
        path = opts.path,
        root = project.root,
        source = opts.source,
    })
end

local function path_signature(path)
    -- Prefer changedtick for open buffers so cached previews follow unsaved
    -- edits instead of only disk mtimes.
    local bufnr = util.loaded_buffer_for_path(path)
    if bufnr then
        return ("buffer:%d"):format(vim.api.nvim_buf_get_changedtick(bufnr))
    end

    local stat = type(path) == "string" and uv.fs_stat(path) or nil
    if not stat then
        return "missing"
    end
    return ("file:%d:%d:%d"):format(
        stat.size or 0,
        (stat.mtime and stat.mtime.sec) or 0,
        (stat.mtime and stat.mtime.nsec) or 0
    )
end

local function document_signature(project)
    -- Page renders depend on the whole known project graph, not just main.typ:
    -- imports, bibliography files, and index generation can all affect output.
    local graph = graph_service.get(project) or {}
    local project_index = index_service.get(project) or {}
    local paths = {}
    paths[project.main] = true
    for path in pairs(graph.dependencies or {}) do
        paths[path] = true
    end
    for path in pairs(graph.files or {}) do
        paths[path] = true
    end

    local parts = {}
    for path in pairs(paths) do
        parts[#parts + 1] = ("%s\0%s"):format(path, path_signature(path))
    end
    table.sort(parts)
    parts[#parts + 1] = "index"
    parts[#parts + 1] = tostring(project_index.generation or 0)
    return table.concat(parts, "\n")
end

local function output_path(project, kind, opts)
    local cfg = render_config(opts)
    local format = opts.format or cfg.output_format or "svg"
    if kind == "page" and not opts.document_signature then
        opts = vim.tbl_extend(
            "force",
            opts,
            { document_signature = document_signature(project) }
        )
    end
    local key = cache_key(
        project,
        kind,
        vim.tbl_extend("force", opts, { format = format })
    )
    local path, path_error = output_path_util.safe_output_path(project, {
        output_format = format,
        output_name = key,
        output_dir = cfg.output_dir or config.default_render_output_dir(),
        allow_external_output = cfg.allow_external_output == true
            or config.unsafe_get().allow_external_output == true,
    }, {
        operation = "render",
    })
    if path_error or not path then
        return key,
            nil,
            nil,
            nil,
            path_error or {
                ok = false,
                pending = false,
                reason = "output_path_invalid",
                message = "Invalid Typst render output path",
            }
    end
    local source_path = project.main
    local stdin_source = false
    if kind ~= "page" then
        if cfg.source_mode == "file" then
            local source_dir = util.resolve_path(
                cfg.source_dir or config.default_render_source_dir(),
                project.root
            )
            source_path = util.join(source_dir, ("%s.typ"):format(key))
        else
            stdin_source = true
            source_path = ("<typst.nvim-render:%s>"):format(key)
        end
    end
    return key, path, source_path, stdin_source, nil
end

local provider_render_result

function provider_render_result(result, opts, notify)
    if type(result) ~= "table" then
        return result
    end
    if result.pending == true then
        return result
    end
    if result.ok == false then
        notify_user(
            notify,
            result.message or "Typst render provider failed",
            vim.log.levels.ERROR
        )
        return result
    end
    return render_display.display(result, opts, notify)
end

local function call_render_provider(
    project,
    kind,
    opts,
    callback,
    notify,
    generation,
    token
)
    return render_provider.call(project, kind, opts, {
        callback = callback,
        finalize_result = function(result, provider_opts)
            return provider_render_result(result, provider_opts, notify)
        end,
        generation = generation,
        is_stale = function(stale_project, stale_kind, stale_generation)
            return render_stale(
                stale_project,
                stale_kind,
                stale_generation,
                token
            )
        end,
        render_config = render_config,
        rollback_generation = rollback_render_generation,
        stale_result = function(stale_kind, stale_generation)
            return stale_render_result(stale_kind, stale_generation, token)
        end,
    })
end

local function apply_stale_result(target, stale)
    for key, value in pairs(stale or {}) do
        target[key] = value
    end
    target.pending = false
    return target
end

local function command_for(project, source_path, output, opts)
    local cfg = config.unsafe_get()
    local compile_root = opts.compile_root or project.root
    local command = vim.list_extend(util.command_prefix(cfg.executable), {
        "compile",
        "--root",
        compile_root,
        "--format",
        opts.format or render_config(opts).output_format or "svg",
    })
    if opts.page then
        command[#command + 1] = "--pages"
        command[#command + 1] = tostring(opts.page)
    end

    for _, arg in ipairs(opts.extra_args or {}) do
        command[#command + 1] = arg
    end

    command[#command + 1] = opts.stdin_source and "-" or source_path
    command[#command + 1] = output
    return command
end

local function write_source(path, source)
    return util.atomic_writefile(
        vim.split(source, "\n", { plain = true }),
        path
    )
end

local function virtual_source_path(path)
    return type(path) == "string"
        and path:match("^<typst%.nvim%-render:") ~= nil
end

local function generated_source_mode(project, source_path, stdin_source)
    if stdin_source then
        return "stdin"
    end

    local dir = util.dirname(source_path)
    local xdg_source_dir = config.default_render_source_dir()
    if
        util.path_within(dir, xdg_source_dir)
        or util.same_path(dir, xdg_source_dir)
    then
        return "file"
    end

    if util.path_within(dir, project.root) then
        if util.same_path(dir, project.root) then
            return nil,
                "unsafe_source_dir",
                "Typst render source directory must not be the project root"
        end
        return "file"
    end

    return nil,
        "source_outside_root",
        ("Typst render file source directory must be inside the project root or default render source cache: %s"):format(
            dir
        )
end

local function cleanup_generated_source(project, source_path, reason)
    if
        not source_path
        or virtual_source_path(source_path)
        or util.same_path(source_path, project.main)
        or vim.fn.filereadable(source_path) ~= 1
    then
        return false
    end

    local ok, err = util.delete_checked(source_path)
    if not ok then
        log.add("warn", "failed to delete Typst render source", {
            path = source_path,
            reason = reason,
            error = err,
        })
        return false
    end
    return true
end

local function delete_cache_source(dir, source_path)
    if
        type(source_path) == "string"
        and source_path ~= ""
        and not virtual_source_path(source_path)
        and util.path_within(source_path, dir)
        and not util.same_path(source_path, dir)
    then
        return output_policy.delete_render_cache_file(dir, source_path)
    end
    return true
end

local function compile_root_for_source(project, source_path, source_mode)
    if source_mode ~= "file" then
        return project.root
    end

    local dir = util.dirname(source_path)
    if util.path_within(dir, project.root) then
        return project.root
    end
    return config.default_render_source_dir()
end

local function cached_result(project, kind, opts)
    local options = cache_options(opts)
    if not options.enabled or options.max_entries == 0 then
        return nil
    end

    local key, path, source_path, _, path_error =
        output_path(project, kind, opts)
    if path_error or not path then
        return nil
    end
    local entry = cache[key]
    if entry and entry.path == path and vim.fn.filereadable(path) == 1 then
        local now = now_ms()
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

    local now = now_ms()
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
            or render_config(opts).output_format
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

local function cleanup_unremembered(result, project, reason)
    if not result or result.remembered then
        return
    end

    local cache_dir = result.path and util.dirname(result.path) or nil
    local deleted_output = result.path
        and vim.fn.filereadable(result.path) == 1
        and output_policy.delete_render_cache_file(cache_dir, result.path)
    local deleted_source =
        cleanup_generated_source(project, result.source_path, reason)

    if deleted_output or deleted_source then
        log.add("debug", "removed unremembered render files", {
            kind = result.kind,
            path = result.path,
            source_path = result.source_path,
            reason = reason,
        })
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
        local options = cache_options(opts)
        if not options.enabled or options.max_entries == 0 then
            return
        end

        local now = now_ms()
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

local function render_source(project, kind, source, opts, callback, notify)
    opts = opts or {}
    opts.source = source
    opts.format = opts.format or render_config(opts).output_format or "svg"
    local generation = start_render_generation(project, kind)
    local manager_token = resource_manager.token(project, "render:" .. kind)
    local key, path, source_path, stdin_source, path_error =
        output_path(project, kind, opts)
    if path_error or not path then
        rollback_render_generation(project, kind, generation)
        local result = vim.tbl_extend("force", path_error or {
            ok = false,
            reason = "output_path_invalid",
            message = "Invalid Typst render output path",
        }, {
            pending = false,
            kind = kind,
        })
        if callback then
            callback(result, providers.project_context(project))
        end
        return result
    end
    opts.output_path = opts.output_path or path
    opts.source_path = opts.source_path or source_path
    opts.stdin_source = opts.stdin_source or stdin_source

    local provider_result = call_render_provider(
        project,
        kind,
        opts,
        callback,
        notify,
        generation,
        manager_token
    )
    if provider_result ~= nil then
        if type(provider_result) == "table" then
            provider_result.kind = provider_result.kind or kind
            return provider_render_result(provider_result, opts, notify)
        end
        return provider_result
    end

    local hit = cached_result(project, kind, opts)
    if hit then
        return render_display.display(hit, opts, notify)
    end

    -- Reserve output before writing the temporary source so compile/export/watch
    -- jobs cannot target the same preview file while this render is pending.
    local lease, lease_err = output_ownership.acquire(path, {
        kind = "render-" .. kind,
        project_key = project.key,
        main = project.main,
        generation = generation,
    })
    if not lease then
        ---@cast lease_err table
        rollback_render_generation(project, kind, generation)
        return {
            ok = false,
            pending = false,
            reason = lease_err.reason,
            message = lease_err.message,
            active_output = lease_err.active_output or path,
            path = path,
        }
    end

    local parent_ok, parent_err = output_ownership.ensure_parent(path)
    if not parent_ok then
        output_ownership.release(lease)
        rollback_render_generation(project, kind, generation)
        return {
            ok = false,
            pending = false,
            reason = "parent_create_failed",
            message = tostring(parent_err),
            path = path,
        }
    end

    local source_mode, source_reason, source_message =
        generated_source_mode(project, source_path, stdin_source)
    if not source_mode then
        output_ownership.release(lease)
        rollback_render_generation(project, kind, generation)
        return {
            ok = false,
            reason = source_reason,
            message = source_message,
            path = path,
            source_path = source_path,
        }
    end

    if source_mode == "file" then
        local ok, err = write_source(source_path, source)
        if not ok then
            output_ownership.release(lease)
            rollback_render_generation(project, kind, generation)
            return {
                ok = false,
                reason = "write_failed",
                message = tostring(err),
                path = path,
            }
        end
    end

    opts.stdin_source = source_mode == "stdin"
    opts.compile_root =
        compile_root_for_source(project, source_path, source_mode)
    local command = command_for(project, source_path, path, opts)
    local result = {
        ok = true,
        pending = true,
        key = key,
        kind = kind,
        path = path,
        source_path = source_path,
        format = opts.format,
        command = command,
        cached = false,
    }
    operation.attach(result, ("render-%s"):format(kind), command, {
        cwd = project.root,
        text = true,
        detach = false,
        stdin = opts.stdin_source and source or nil,
    }, {
        owner = "project",
        project_key = project.key,
        cleanup = function()
            output_ownership.release(lease)
        end,
        on_finish = function(exit)
            if async.cancelled(result) then
                cleanup_unremembered(result, project, "cancelled")
                return
            end
            local stale = render_stale(project, kind, generation, manager_token)
                    and stale_render_result(kind, generation, manager_token)
                or nil
            if stale then
                apply_stale_result(result, stale)
                if callback then
                    callback(result, providers.project_context(project))
                end
                cleanup_unremembered(result, project, "stale_result")
                return
            end
            result.pending = false
            result.code = exit.code
            result.stdout = exit.stdout
            result.stderr = exit.stderr
            result.ok = exit.code == 0 and vim.fn.filereadable(path) == 1
            if result.ok then
                remember(result, opts)
                events.emit("TypstRenderCreated", project, {
                    kind = kind,
                    path = path,
                    source = source_path,
                    format = opts.format,
                })
                render_display.display(result, opts, notify)
                cleanup_generated_source(project, source_path, "finished")
            else
                log.add("error", "render failed", {
                    kind = kind,
                    path = path,
                    stderr = exit.stderr,
                    stdout = exit.stdout,
                })
                cleanup_generated_source(project, source_path, "failed")
                notify_user(
                    notify,
                    "Typst rendered preview failed",
                    vim.log.levels.ERROR
                )
            end
            if callback then
                callback(result, providers.project_context(project))
            end
        end,
    })
    return result
end

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

    return render_source(
        project,
        "fragment",
        source,
        vim.tbl_extend("force", opts, { range = range }),
        callback,
        notify
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
    return render_source(project, "equation", source, opts, callback, notify)
end

--- Render the current page or main document into a preview artifact.
---@param project table Project state whose main document should be rendered.
---@param opts? table Render options, including page, format, cache, and display provider.
---@param callback? fun(result:table, project:table) Callback invoked with render result.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table result Render result or pending operation handle.
function M.page(project, opts, callback, notify)
    opts = opts or {}
    opts.format = opts.format or render_config(opts).output_format or "svg"
    opts.source = project.main
    opts.page = opts.page or 1
    local generation = start_render_generation(project, "page")
    local manager_token = resource_manager.token(project, "render:page")
    local function finish_failure(result)
        if callback then
            callback(result, providers.project_context(project))
        end
        return result
    end
    local key, path, _, _, path_error = output_path(project, "page", opts)
    if path_error or not path then
        rollback_render_generation(project, "page", generation)
        return finish_failure(vim.tbl_extend("force", path_error or {
            ok = false,
            reason = "output_path_invalid",
            message = "Invalid Typst render output path",
        }, {
            pending = false,
            kind = "page",
        }))
    end
    opts.output_path = opts.output_path or path

    local provider_result = call_render_provider(
        project,
        "page",
        opts,
        callback,
        notify,
        generation,
        manager_token
    )
    if provider_result ~= nil then
        if type(provider_result) == "table" then
            provider_result.kind = provider_result.kind or "page"
            return provider_render_result(provider_result, opts, notify)
        end
        return provider_result
    end

    local hit = cached_result(project, "page", opts)
    if hit then
        hit.page = opts.page
        return render_display.display(hit, opts, notify)
    end

    local lease, lease_err = output_ownership.acquire(path, {
        kind = "render-page",
        project_key = project.key,
        main = project.main,
        generation = generation,
    })
    if not lease then
        ---@cast lease_err table
        rollback_render_generation(project, "page", generation)
        return finish_failure({
            ok = false,
            pending = false,
            reason = lease_err.reason,
            message = lease_err.message,
            active_output = lease_err.active_output or path,
            path = path,
        })
    end
    local parent_ok, parent_err = output_ownership.ensure_parent(path)
    if not parent_ok then
        output_ownership.release(lease)
        rollback_render_generation(project, "page", generation)
        return finish_failure({
            ok = false,
            pending = false,
            reason = "parent_create_failed",
            message = tostring(parent_err),
            path = path,
        })
    end
    local command = command_for(project, project.main, path, opts)
    local result = {
        ok = true,
        pending = true,
        key = key,
        kind = "page",
        path = path,
        source_path = project.main,
        format = opts.format,
        page = opts.page,
        command = command,
        cached = false,
    }
    operation.attach(result, "render-page", command, {
        cwd = project.root,
        text = true,
        detach = false,
    }, {
        owner = "project",
        project_key = project.key,
        cleanup = function()
            output_ownership.release(lease)
        end,
        on_finish = function(exit)
            if async.cancelled(result) then
                cleanup_unremembered(result, project, "cancelled")
                return
            end
            local stale = render_stale(
                project,
                "page",
                generation,
                manager_token
            ) and stale_render_result(
                "page",
                generation,
                manager_token
            ) or nil
            if stale then
                apply_stale_result(result, stale)
                if callback then
                    callback(result, providers.project_context(project))
                end
                cleanup_unremembered(result, project, "stale_result")
                return
            end
            result.pending = false
            result.code = exit.code
            result.stdout = exit.stdout
            result.stderr = exit.stderr
            result.ok = exit.code == 0 and vim.fn.filereadable(path) == 1
            if result.ok then
                remember(result, opts)
                events.emit("TypstRenderCreated", project, {
                    kind = "page",
                    path = path,
                    source = project.main,
                    format = opts.format,
                    page = opts.page,
                })
                render_display.display(result, opts, notify)
            else
                notify_user(
                    notify,
                    "Typst page preview failed",
                    vim.log.levels.ERROR
                )
            end
            if callback then
                callback(result, providers.project_context(project))
            end
        end,
    })
    return result
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
    local dir = util.resolve_path(
        render_config(opts).output_dir or config.default_render_output_dir(),
        root
    )
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

return M
