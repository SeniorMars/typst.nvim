local config = require("typst.config")
local graph_sources = require("typst.project.graph.sources")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local util = require("typst.core.util")

local M = {
    name = "typst-query",
}

local cache = {}

local expression = [[
{ let block(it, kind) = (kind: kind, element: it, page: it.location().page(), position: it.location().position()); query(heading).map(it => block(it, "heading")) + query(par).map(it => block(it, "par")) }
]]

local function json_decode(text)
    local decoder = vim.json and vim.json.decode or vim.fn.json_decode
    local ok, decoded = pcall(decoder, text)
    return ok and decoded or nil
end

local function output_supported(path)
    return type(path) == "string"
        and path ~= ""
        and vim.fn.fnamemodify(path, ":e"):lower() == "svg"
        and vim.fn.filereadable(path) == 1
end

function M.capabilities(_, request)
    local supported = output_supported(request and request.output)
    return {
        forward = supported,
        inverse = supported,
        source_maps = supported,
        browser_click = supported,
    }
end

local function parse_pt(value)
    if type(value) == "number" then
        return value
    end
    if type(value) ~= "string" then
        return nil
    end
    return tonumber(value:match("^-?%d+%.?%d*"))
end

local function append_text(parts, value)
    if type(value) == "string" then
        parts[#parts + 1] = value
        return
    end
    if type(value) ~= "table" then
        return
    end
    if value.func == "text" and type(value.text) == "string" then
        parts[#parts + 1] = value.text
        return
    end
    if value.func == "space" then
        parts[#parts + 1] = " "
        return
    end
    if type(value.body) == "table" then
        append_text(parts, value.body)
    end
    if type(value.child) == "table" then
        append_text(parts, value.child)
    end
    if type(value.children) == "table" then
        for _, child in ipairs(value.children) do
            append_text(parts, child)
        end
    end
end

local function element_text(block)
    local element = block and block.element
    if type(element) ~= "table" then
        return ""
    end
    local parts = {}
    append_text(parts, element.body or element)
    return table
        .concat(parts)
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function normalize_text(text)
    text = tostring(text or ""):lower()
    text = text:gsub("//.*$", "")
    text = text:gsub("^%s*=+%s*", "")
    text = text:gsub("#[%a_][%w_%-%.]*%s*%[", " ")
    text = text:gsub("[#%[%]{}%$%*`_~=<>]", " ")
    text = text:gsub("%s+", " ")
    return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function tokens(text)
    local out = {}
    local seen = {}
    for token in normalize_text(text):gmatch("[%w_%-]+") do
        if #token >= 2 and not seen[token] then
            seen[token] = true
            out[#out + 1] = token
        end
    end
    return out
end

local function buffer_lines(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
        local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
        if ok then
            return lines
        end
    end
    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or nil
end

local function source_files(project)
    local files = {}
    local seen = {}
    local function add(path)
        if
            type(path) == "string"
            and path ~= ""
            and vim.fn.fnamemodify(path, ":e"):lower() == "typ"
        then
            local normalized = util.normalize(path)
            if not seen[normalized] then
                seen[normalized] = true
                files[#files + 1] = normalized
            end
        end
    end

    add(project.main)
    local live_project = nil
    if project.key then
        live_project = require("typst.project.store").all()[project.key]
    end
    for path, value in
        pairs(
            (live_project and graph_sources.get(live_project))
                or project.files
                or {}
        )
    do
        path = type(path) == "string" and path or value
        add(path)
    end
    table.sort(files, function(left, right)
        if util.same_path(left, project.main) then
            return true
        end
        if util.same_path(right, project.main) then
            return false
        end
        return left < right
    end)
    return files
end

local function source_index(project)
    local lines = {}
    for _, path in ipairs(source_files(project)) do
        local source_lines = buffer_lines(path)
        if source_lines then
            for line_nr, line in ipairs(source_lines) do
                local normalized = normalize_text(line)
                if normalized ~= "" then
                    lines[#lines + 1] = {
                        path = path,
                        line = line_nr,
                        raw = line,
                        text = normalized,
                        tokens = tokens(line),
                    }
                end
            end
        end
    end
    return lines
end

local function score_line(block_tokens, block_text, line)
    if #block_tokens == 0 or #line.tokens == 0 then
        return 0
    end

    local score = 0
    for _, token in ipairs(block_tokens) do
        if line.text:find(token, 1, true) then
            score = score + 2
        end
    end
    if block_text:find(line.text, 1, true) then
        score = score + 3
    end
    if line.text:find(block_text, 1, true) then
        score = score + 3
    end
    return score
end

local function best_source_line(source_lines, text)
    local block_text = normalize_text(text)
    local block_tokens = tokens(text)
    local best = nil
    local best_score = 0
    for _, line in ipairs(source_lines) do
        local score = score_line(block_tokens, block_text, line)
        if score > best_score then
            best = line
            best_score = score
        end
    end
    if not best or best_score < math.max(2, math.ceil(#block_tokens / 3)) then
        return nil
    end
    return best
end

local function column_for(line, text)
    local first = tokens(text)[1]
    if first then
        local start = normalize_text(line.raw):find(first, 1, true)
        if start then
            return start
        end
    end
    return 1
end

local function command_for(project)
    local opts = config.unsafe_get()
    local command = util.command_prefix(opts.executable)
    command[#command + 1] = "eval"
    command[#command + 1] = "--root"
    command[#command + 1] = project.root
    for _, arg in ipairs((opts.compile or {}).extra_args or {}) do
        command[#command + 1] = arg
    end
    command[#command + 1] = "--in"
    command[#command + 1] = project.main
    command[#command + 1] = "--format"
    command[#command + 1] = "json"
    command[#command + 1] = expression
    return command
end

local function decode_query_result(result)
    if type(result) ~= "table" or result.code ~= 0 then
        return nil,
            result and (result.stderr or result.stdout) or "query failed"
    end
    local decoded = json_decode(result.stdout or "")
    if type(decoded) ~= "table" then
        return nil, "typst query did not return JSON"
    end
    return decoded
end

local function pending_handle(kind, operation_handle, transform, callback)
    local callbacks = {}
    local handle = {
        ok = true,
        pending = true,
        kind = kind,
        operation = operation_handle,
        handle = operation_handle and operation_handle.handle or nil,
    }

    local function finish(raw)
        if handle.result ~= nil then
            return handle.result
        end
        handle.pending = false
        handle.result = transform(raw)
        if type(callback) == "function" then
            pcall(callback, handle.result)
        end
        for _, item in ipairs(callbacks) do
            pcall(item, handle.result, handle)
        end
        callbacks = {}
        return handle.result
    end

    function handle:on_finish(item)
        if type(item) ~= "function" then
            return self
        end
        if self.result ~= nil then
            pcall(item, self.result, self)
        else
            callbacks[#callbacks + 1] = item
        end
        return self
    end

    function handle.cancel(self_or_opts, maybe_opts)
        local opts = self_or_opts == handle and maybe_opts or self_or_opts
        if handle.result ~= nil then
            return false, handle.result
        end
        if type(operation_handle) ~= "table" then
            return false
        end
        return operation_handle:cancel(opts or {
            reason = "cancelled",
        })
    end

    if type(operation_handle) == "table" then
        operation_handle:on_finish(finish)
    else
        finish({
            ok = false,
            reason = "spawn_failed",
            message = "source-map operation did not start",
        })
    end

    return handle
end

local function run_query(project, callback)
    local command = command_for(project)
    local query_operation = operation.run("preview-source-map", command, {
        cwd = project.root,
        text = true,
        detach = false,
    }, {
        timeout_ms = 10000,
    })
    return pending_handle(
        "preview-source-map",
        query_operation,
        function(result)
            local decoded, err = decode_query_result(result)
            if decoded then
                return {
                    ok = true,
                    blocks = decoded,
                }
            end
            return {
                ok = false,
                reason = "query_failed",
                provider = M.name,
                message = tostring(err),
            }
        end,
        callback
    )
end

local function cache_key(project, request)
    local output = request and request.output or ""
    local stat = output ~= "" and (vim.uv or vim.loop).fs_stat(output) or nil
    local mtime = stat
            and stat.mtime
            and (stat.mtime.sec .. "." .. stat.mtime.nsec)
        or ""
    return table.concat({
        project.key or "",
        project.root or "",
        project.main or "",
        output,
        tostring(request and request.generation or ""),
        mtime,
        tostring(config.generation()),
    }, "\n")
end

local function unsupported_output(request)
    if not output_supported(request.output) then
        return {
            ok = false,
            reason = "unsupported_output",
            provider = M.name,
            message = "typst-query source maps require a readable SVG preview output",
            output = request.output,
        }
    end
    return nil
end

local function build_map(project, request, blocks)
    local sources = source_index(project)
    local anchors = {}
    for _, block in ipairs(blocks or {}) do
        local text = element_text(block)
        local position = block.position or {}
        local source = best_source_line(sources, text)
        local x = parse_pt(position.x)
        local y = parse_pt(position.y)
        if source and x and y then
            anchors[#anchors + 1] = {
                path = source.path,
                line = source.line,
                column = column_for(source, text),
                page = tonumber(block.page or position.page) or 1,
                x = x,
                y = y,
                kind = block.kind,
                text = text,
            }
        end
    end

    local result = {
        ok = #anchors > 0,
        provider = M.name,
        output = request.output,
        generation = request.generation,
        anchors = anchors,
        blocks = #(blocks or {}),
    }
    if #anchors == 0 then
        result.reason = "empty_source_map"
        result.message =
            "typst-query could not match Typst layout blocks to source lines"
    end
    return result
end

function M.generate(project, request, callback)
    request = request or {}
    local unsupported = unsupported_output(request)
    if unsupported then
        if type(callback) == "function" then
            callback(unsupported)
        end
        return unsupported
    end

    local key = cache_key(project, request)
    if cache[key] then
        if type(callback) == "function" then
            callback(cache[key])
        end
        return cache[key]
    end

    local query = run_query(project)
    if type(query) ~= "table" or query.pending ~= true then
        return query
    end

    return pending_handle(
        "preview-source-map-generate",
        query.operation,
        function()
            local query_result = query.result
            local result = query_result.ok == false
                    and vim.tbl_extend("force", query_result, {
                        output = request.output,
                    })
                or build_map(project, request, query_result.blocks)
            cache[key] = result
            if result.ok == false then
                log.add(
                    "warn",
                    "typst-query source-map generation failed",
                    result
                )
            end
            return result
        end,
        callback
    )
end

local function nearest_anchor(map, request)
    local page = tonumber(request.page) or 1
    local x = tonumber(request.x) or 0
    local y = tonumber(request.y) or 0
    local best = nil
    local best_score = math.huge
    for _, anchor in ipairs(map.anchors or {}) do
        if tonumber(anchor.page) == page then
            local dx = math.abs((anchor.x or 0) - x)
            local dy = math.abs((anchor.y or 0) - y)
            local score = dy * 4 + dx
            if score < best_score then
                best = anchor
                best_score = score
            end
        end
    end
    return best
end

local function nearest_line_anchor(map, request)
    local path = request.path
    local line = tonumber(request.line or (request.position or {}).line) or 1
    local best = nil
    local best_score = math.huge
    for _, anchor in ipairs(map.anchors or {}) do
        local path_penalty = path
                and not util.same_path(path, anchor.path)
                and 10000
            or 0
        local score = math.abs((anchor.line or 1) - line) + path_penalty
        if score < best_score then
            best = anchor
            best_score = score
        end
    end
    return best
end

local function source_result(anchor, extra)
    if not anchor then
        return {
            ok = false,
            reason = "no_source_anchor",
            provider = M.name,
            message = "No source-map anchor matched the requested preview location",
        }
    end
    return vim.tbl_extend("force", {
        ok = true,
        provider = M.name,
        path = anchor.path,
        line = anchor.line,
        column = anchor.column or 1,
        page = anchor.page,
        x = anchor.x,
        y = anchor.y,
        text = anchor.text,
    }, extra or {})
end

local function resolve_from_map(map, request)
    if type(map) == "table" and map.ok == false then
        return map
    end
    if request.action == "forward" then
        return source_result(nearest_line_anchor(map, request), {
            source_sync = "forward",
        })
    end
    return source_result(nearest_anchor(map, request), {
        source_sync = "browser-inverse",
    })
end

function M.resolve(project, request, callback)
    request = request or {}
    local map = M.generate(project, request)
    if type(map) == "table" and map.pending == true then
        return pending_handle(
            "preview-source-map-resolve",
            map.operation,
            function()
                return resolve_from_map(map.result, request)
            end,
            callback
        )
    end

    local result = resolve_from_map(map, request)
    if type(callback) == "function" then
        callback(result)
    end
    return result
end

function M.forward(project, request, callback)
    request = vim.tbl_extend("force", request or {}, {
        action = "forward",
    })
    return M.resolve(project, request, callback)
end

function M.inverse(project, request, callback)
    request = vim.tbl_extend("force", request or {}, {
        action = "inverse",
    })
    return M.resolve(project, request, callback)
end

function M.browser_inverse(project, request, callback)
    request = vim.tbl_extend("force", request or {}, {
        action = "browser_inverse",
    })
    return M.resolve(project, request, callback)
end

function M._reset_for_tests()
    cache = {}
end

M.reset = M._reset_for_tests

return M
