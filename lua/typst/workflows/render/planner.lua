local config = require("typst.config")
local output_path_util = require("typst.compiler.output_path")
local graph_service = require("typst.project.services.graph")
local index_service = require("typst.project.services.index")
local render_cache = require("typst.workflows.render.cache")
local util = require("typst.core.util")

local M = {}

local uv = vim.uv or vim.loop

function M.render_config(opts)
    opts = opts or {}
    return vim.tbl_extend("force", config.unsafe_get().render or {}, opts or {})
end

function M.cache_options(opts)
    return render_cache.options(M.render_config(opts), opts or {})
end

function M.now_ms()
    if uv and type(uv.now) == "function" then
        return uv.now()
    end
    return math.floor(vim.loop.hrtime() / 1000000)
end

local function table_is_list(value)
    local count = 0
    local max_index = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        count = count + 1
        max_index = math.max(max_index, key)
    end
    return count == max_index
end

function M.stable_encode(value, seen)
    local kind = type(value)
    if kind == "nil" then
        return "nil"
    end
    if kind == "string" then
        return ("string:%d:%s"):format(#value, value)
    end
    if kind == "number" or kind == "boolean" then
        return kind .. ":" .. tostring(value)
    end
    if kind ~= "table" then
        return kind .. ":" .. tostring(value)
    end

    seen = seen or {}
    if seen[value] then
        return "table:<cycle>"
    end
    seen[value] = true

    local encoded
    if table_is_list(value) then
        local parts = {}
        for index = 1, #value do
            parts[#parts + 1] = M.stable_encode(value[index], seen)
        end
        encoded = "list:[" .. table.concat(parts, ",") .. "]"
    else
        local keys = vim.tbl_keys(value)
        table.sort(keys, function(left, right)
            return M.stable_encode(left) < M.stable_encode(right)
        end)
        local parts = {}
        for _, key in ipairs(keys) do
            parts[#parts + 1] = ("%s=>%s"):format(
                M.stable_encode(key, seen),
                M.stable_encode(value[key], seen)
            )
        end
        encoded = "map:{" .. table.concat(parts, ",") .. "}"
    end

    seen[value] = nil
    return encoded
end

function M.hash_key(parts)
    local keys = vim.tbl_keys(parts)
    table.sort(keys)
    local encoded = {}
    for _, key in ipairs(keys) do
        encoded[#encoded + 1] = M.stable_encode(key)
            .. "="
            .. M.stable_encode(parts[key])
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

function M.cache_key(project, kind, opts)
    opts = opts or {}
    return M.hash_key({
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

function M.document_signature(project)
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

function M.output_path(project, kind, opts)
    opts = opts or {}
    local cfg = M.render_config(opts)
    local format = opts.format or cfg.output_format or "svg"
    if kind == "page" and not opts.document_signature then
        opts = vim.tbl_extend(
            "force",
            opts,
            { document_signature = M.document_signature(project) }
        )
    end
    local key = M.cache_key(
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

function M.command_for(project, source_path, output, opts)
    opts = opts or {}
    local cfg = config.unsafe_get()
    local compile_root = opts.compile_root or project.root
    local command = vim.list_extend(util.command_prefix(cfg.executable), {
        "compile",
        "--root",
        compile_root,
        "--format",
        opts.format or M.render_config(opts).output_format or "svg",
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

function M.write_source(path, source)
    return util.atomic_writefile(
        vim.split(source, "\n", { plain = true }),
        path
    )
end

function M.virtual_source_path(path)
    return type(path) == "string"
        and path:match("^<typst%.nvim%-render:") ~= nil
end

function M.generated_source_mode(project, source_path, stdin_source)
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

function M.compile_root_for_source(project, source_path, source_mode)
    if source_mode ~= "file" then
        return project.root
    end

    local dir = util.dirname(source_path)
    if util.path_within(dir, project.root) then
        return project.root
    end
    return config.default_render_source_dir()
end

function M.cache_dir(opts, root)
    return util.resolve_path(
        M.render_config(opts).output_dir or config.default_render_output_dir(),
        root
    )
end

return M
