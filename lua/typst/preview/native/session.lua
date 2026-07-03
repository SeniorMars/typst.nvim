local util = require("typst.core.util")
local project_id = require("typst.core.project_id")

local uv = vim.uv or vim.loop

local M = {}

local routes = {}
local files = {}
local refresh_generations = {}
local forward_generations = {}

local function encode_component(value)
    value = tostring(value or "")
    return (
        value:gsub("([^%w%-_%.~])", function(char)
            return ("%%%02X"):format(char:byte())
        end)
    )
end

local function hex(bytes)
    local out = {}
    for index = 1, #bytes do
        out[#out + 1] = ("%02x"):format(bytes:byte(index))
    end
    return table.concat(out)
end

local function random_token()
    if uv and type(uv.random) == "function" then
        local ok, bytes = pcall(uv.random, 16)
        if ok and type(bytes) == "string" and #bytes > 0 then
            return hex(bytes)
        end
    end
    return vim.fn
        .sha256(
            ("%s:%s:%s:%s"):format(
                uv and uv.hrtime() or os.clock(),
                uv and uv.os_getpid() or 0,
                math.random(),
                tostring({})
            )
        )
        :sub(1, 32)
end

local function loopback_host(host)
    return host == "127.0.0.1"
        or host == "localhost"
        or host == "::1"
        or host == "[::1]"
end

function M.remote_token(browser, host)
    if loopback_host(host or "127.0.0.1") then
        return nil
    end

    local token = browser and browser.token or "auto"
    if type(token) == "string" and token ~= "" and token ~= "auto" then
        return token
    end
    return random_token()
end

function M.project_id(project)
    return project_id.project_id(project)
end

function M.resource_path(route, leaf)
    local path = ("/preview/%s/"):format(route.id)
    if type(leaf) == "string" and leaf ~= "" and leaf ~= "index" then
        path = path .. leaf
    end
    if type(route.token) == "string" and route.token ~= "" then
        path = path .. "?token=" .. encode_component(route.token)
    end
    return path
end

function M.relative_resource_path(route, leaf)
    local path = leaf or ""
    if path == "" or path == "index" then
        path = "."
    end
    if type(route.token) == "string" and route.token ~= "" then
        path = path .. "?token=" .. encode_component(route.token)
    end
    return path
end

function M.route_url(route)
    return ("http://%s:%d%s"):format(
        route.host,
        route.port,
        M.resource_path(route, "index")
    )
end

function M.set_route(project, fields)
    local id = M.project_id(project)
    local route = vim.tbl_extend("force", fields or {}, {
        id = id,
        main = project.main,
        root = project.root,
        project_key = project.key,
    })
    routes[id] = route
    return route
end

function M.route_for_id(id)
    return routes[id]
end

function M.route_count()
    return vim.tbl_count(routes)
end

local function item_matches_project(item, project)
    return item
        and (
            item.project_key == project.key
            or (item.main == project.main and item.root == project.root)
        )
end

function M.route_for_project(project)
    local direct = routes[M.project_id(project)]
    if item_matches_project(direct, project) then
        return direct
    end
    for _, route in pairs(routes) do
        if item_matches_project(route, project) then
            return route
        end
    end
    return nil
end

function M.clear_route(project)
    local id = M.project_id(project)
    local route = routes[id]
    if item_matches_project(route, project) then
        routes[id] = nil
        return route
    end
    for route_id, item in pairs(routes) do
        if item_matches_project(item, project) then
            routes[route_id] = nil
            return item
        end
    end
    return nil
end

function M.set_file(project, fields)
    local id = M.project_id(project)
    local item = vim.tbl_extend("force", fields or {}, {
        id = id,
        main = project.main,
        root = project.root,
        project_key = project.key,
    })
    files[id] = item
    return item
end

function M.file_for_id(id)
    return files[id]
end

function M.file_for_project(project)
    local direct = files[M.project_id(project)]
    if item_matches_project(direct, project) then
        return direct
    end
    for _, file in pairs(files) do
        if item_matches_project(file, project) then
            return file
        end
    end
    return nil
end

function M.clear_file(project)
    local id = M.project_id(project)
    local item = files[id]
    if item_matches_project(item, project) then
        files[id] = nil
        return item
    end
    for file_id, file in pairs(files) do
        if item_matches_project(file, project) then
            files[file_id] = nil
            return file
        end
    end
    return nil
end

function M.clear(project)
    local id = M.project_id(project)
    refresh_generations[id] = nil
    forward_generations[id] = nil
    return M.clear_route(project), M.clear_file(project)
end

function M.reset()
    routes = {}
    files = {}
    refresh_generations = {}
    forward_generations = {}
end

function M.next_refresh_generation(project)
    local id = M.project_id(project)
    local generation = (refresh_generations[id] or 0) + 1
    refresh_generations[id] = generation
    return generation
end

function M.current_refresh_generation(project)
    return refresh_generations[M.project_id(project)] or 0
end

function M.refresh_generation_current(project, generation)
    return generation == nil
        or M.current_refresh_generation(project) == generation
end

local function update_project_fields(item, project, fields)
    if not item then
        return nil
    end
    for key, value in pairs(fields or {}) do
        item[key] = value
    end
    item.project_key = project.key
    item.main = project.main
    item.root = project.root
    return item
end

function M.reassign(project, next_project, fields)
    local route = M.route_for_project(project)
    local file = M.file_for_project(project)
    update_project_fields(route, next_project, fields)
    update_project_fields(file, next_project, fields)
    return route, file
end

function M.set_forward_target(project, target)
    local route = M.route_for_project(project)
    if not route or type(target) ~= "table" then
        return nil
    end

    local id = route.id or M.project_id(project)
    local serial = (forward_generations[id] or 0) + 1
    forward_generations[id] = serial
    route.forward_target = vim.tbl_extend("force", {
        serial = serial,
        provider = target.provider,
        source_sync = target.source_sync or "forward",
    }, vim.deepcopy(target))
    return route.forward_target
end

function M.browser_url(project)
    local route = M.route_for_project(project)
    if route then
        return M.route_url(route)
    end
    local file = M.file_for_project(project)
    return file and file.url or nil
end

function M.project_state(project)
    local route = M.route_for_project(project)
    if route then
        return {
            active = true,
            mode = "server",
            url = M.route_url(route),
            output = route.output,
            server_host = route.host,
            server_port = route.port,
            export = vim.deepcopy(route.export),
        }
    end

    local file = M.file_for_project(project)
    if file then
        return {
            active = true,
            mode = "file-shell",
            url = file.url,
            output = file.output,
            shell_path = file.path,
            state_path = file.state_path,
            export = vim.deepcopy(file.export),
        }
    end

    return {
        active = false,
    }
end

local function output_mtime(stat)
    return stat
            and stat.mtime
            and (stat.mtime.sec * 1000000000 + stat.mtime.nsec)
        or nil
end

function M.output_metadata(path)
    local stat = path and uv.fs_stat(path) or nil
    local format = type(path) == "string"
            and vim.fn.fnamemodify(path, ":e"):lower()
        or nil
    local kind = "artifact"
    if format == "pdf" then
        kind = "pdf"
    elseif format == "svg" then
        kind = "svg"
    elseif
        format == "png"
        or format == "jpg"
        or format == "jpeg"
        or format == "gif"
        or format == "webp"
    then
        kind = "image"
    end

    return {
        output_format = format,
        output_kind = kind,
        output_size = stat and stat.size or nil,
        mtime = output_mtime(stat),
    }
end

function M.state_payload(route)
    local metadata = M.output_metadata(route.output)
    return {
        ok = true,
        id = route.id,
        output = route.output,
        output_url = M.relative_resource_path(route, "artifact"),
        output_name = route.output and util.basename(route.output) or nil,
        output_format = metadata.output_format,
        output_kind = metadata.output_kind,
        output_size = metadata.output_size,
        main = route.main,
        root = route.root,
        generation = route.generation,
        mtime = metadata.mtime,
        source_sync = vim.deepcopy(route.source_sync or {}),
        sync_url = M.relative_resource_path(route, "source-sync"),
        token_required = type(route.token) == "string" and route.token ~= "",
        forward_target = vim.deepcopy(route.forward_target),
    }
end

function M.generation(result)
    return tostring(
        (
            result
            and (result.cycle_generation or result.generation or result.cycle)
        ) or uv.hrtime()
    )
end

return M
