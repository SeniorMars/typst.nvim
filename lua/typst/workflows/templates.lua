local config = require("typst.config")
local async = require("typst.core.async")
local log = require("typst.core.log")
local operation = require("typst.core.operation")
local package_cache = require("typst.package.cache")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local reports = require("typst.ui.reports")
local semver = require("typst.core.semver")
local template_files = require("typst.package.template_files")
local util = require("typst.core.util")

local M = {}

local notify_user = require("typst.core.notify").user

local function provider_init(opts, callback)
    local provider = providers.resolve("init", opts.provider)
    if provider == nil or provider == "typst" then
        return nil
    end
    return provider_adapter.invoke(provider, { "init", "run" }, opts, nil, {
        kind = "init",
        provider_name = type(provider) == "table" and provider.name
            or "callback",
        args = { opts },
        callback_position = 2,
        timeout_ms = opts.timeout_ms or 10000,
        on_result = callback,
        result_fields = {
            path = true,
            files = true,
            created = true,
            template = true,
            output = true,
            stdout = true,
            stderr = true,
        },
        invalid_result_message = "Template provider returned no result",
    })
end

local function template_spec(record)
    if record.spec then
        return record.spec
    end
    if record.version then
        return ("@%s/%s:%s"):format(
            record.namespace,
            record.name,
            record.version
        )
    end
    return ("@%s/%s"):format(record.namespace, record.name)
end

local function decode_json_file(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return nil
    end

    local ok_decode, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
    if ok_decode and type(decoded) == "table" then
        return decoded
    end
end

local function universe_candidates(decoded)
    if type(decoded) ~= "table" then
        return {}
    end
    if decoded.name or decoded.spec then
        return { decoded }
    end
    if type(decoded.packages) == "table" then
        return decoded.packages
    end
    return decoded
end

local function normalize_universe_template(raw)
    if type(raw.template) == "table" then
        return raw.template
    end
    if raw.template == true or raw.is_template == true then
        return {}
    end
end

local function universe_record(raw, source_path)
    if type(raw) ~= "table" then
        return nil
    end

    raw = type(raw.package) == "table"
            and vim.tbl_extend("force", raw, raw.package)
        or raw
    local parsed = raw.spec and package_cache.parse_spec(raw.spec) or nil
    local namespace = raw.namespace
        or (parsed and parsed.namespace)
        or "preview"
    local name = raw.name or (parsed and parsed.name)
    local version = raw.version
        or raw.latest_version
        or raw.latest
        or (parsed and parsed.version)
    local template = normalize_universe_template(raw)
    if
        not namespace
        or not name
        or not version
        or type(template) ~= "table"
    then
        return nil
    end

    return {
        spec = ("@%s/%s:%s"):format(namespace, name, version),
        namespace = namespace,
        name = name,
        version = version,
        description = raw.description or raw.summary,
        entrypoint = raw.entrypoint or template.entrypoint,
        compiler = raw.compiler,
        template = template,
        provider = "universe",
        source = "universe_index",
        source_path = source_path,
        cached = false,
    }
end

local function cached_template_record(record)
    local template = vim.deepcopy(record.template or {})
    return {
        spec = template_spec(record),
        namespace = record.namespace,
        name = record.name,
        version = record.version,
        root = record.root,
        manifest = record.manifest,
        entrypoint = record.entrypoint or template.entrypoint,
        entrypoint_error = record.entrypoint_error,
        description = record.description,
        compiler = record.compiler,
        template = template,
        provider = "package",
        source = "cache",
        cached = true,
    }
end

local function add_universe_templates(records, seen, opts)
    local completion_config = config.unsafe_get().completion or {}
    local paths = opts.universe_index_paths
        or completion_config.universe_index_paths
        or {}
    if opts.include_universe == false or type(paths) ~= "table" then
        return
    end

    for _, path in ipairs(paths) do
        local resolved = util.resolve_path(path)
        if resolved and vim.fn.filereadable(resolved) == 1 then
            local decoded = decode_json_file(resolved)
            for _, raw in pairs(universe_candidates(decoded)) do
                local record = universe_record(raw, resolved)
                if record and not seen[record.spec] then
                    seen[record.spec] = true
                    records[#records + 1] = record
                end
            end
        end
    end
end

local function sort_templates(records)
    table.sort(records, function(left, right)
        if left.namespace ~= right.namespace then
            return left.namespace < right.namespace
        end
        if left.name ~= right.name then
            return left.name < right.name
        end
        if left.version ~= right.version then
            return semver.less(left.version or "", right.version or "")
        end
        return left.spec < right.spec
    end)
end

local function open_template_gallery(records)
    local lines = { "typst.nvim templates" }
    for _, record in ipairs(records) do
        lines[#lines + 1] = ("%s  [%s]  %s"):format(
            record.spec,
            record.source,
            record.description or ""
        )
        if
            record.template
            and (record.template.path or record.template.entrypoint)
        then
            lines[#lines + 1] = ("  template: %s%s"):format(
                record.template.path or ".",
                record.template.entrypoint
                        and (" / " .. record.template.entrypoint)
                    or ""
            )
        end
        if record.root then
            lines[#lines + 1] = ("  cache: %s"):format(record.root)
        elseif record.source_path then
            lines[#lines + 1] = ("  index: %s"):format(record.source_path)
        end
    end
    return reports.open_scratch_buffer(
        "typst.nvim templates",
        "typsttemplates",
        lines
    )
end

--- Return available Typst templates from configured providers and cache.
---@param opts? table Template lookup options such as query, provider, and refresh controls.
---@return table[] templates Template records sorted for picker display.
function M.templates(opts)
    opts = opts or {}
    local records = {}
    local seen = {}
    for _, record in ipairs(package_cache.cached_packages(opts.cache or {})) do
        if record.is_template then
            local item = cached_template_record(record)
            seen[item.spec] = true
            records[#records + 1] = item
        end
    end
    add_universe_templates(records, seen, opts)
    sort_templates(records)

    if opts.open then
        open_template_gallery(records)
    end

    return records
end

local function destination_for(template, directory)
    if directory and directory ~= "" then
        return util.canonical(util.resolve_path(directory, vim.fn.getcwd()))
    end

    local spec = package_cache.parse_spec(template)
    if spec then
        return util.canonical(util.resolve_path(spec.name, vim.fn.getcwd()))
    end
end

local function open_initialized_project(destination, opts)
    if opts.open == false or not destination then
        return nil
    end

    local candidates = {
        util.join(destination, "main.typ"),
        util.join(destination, "template", "main.typ"),
    }
    for _, path in ipairs(candidates) do
        if vim.fn.filereadable(path) == 1 then
            util.edit_existing_or_path(path)
            return path
        end
    end
end

local function init_from_cache(template, destination, opts, notify)
    local record = template_files.cached_record(template)
    if not record then
        return {
            ok = false,
            reason = "missing_cached_template",
            template = template,
        }
    end

    local entrypoint, template_dir, reason = template_files.entrypoint(record)
    if reason then
        return {
            ok = false,
            reason = reason,
            template = template,
        }
    end

    local result = template_files.copy_dir(template_dir, destination, {
        overwrite = opts.overwrite == true,
        source_root = record.root,
    })
    result.template = template
    result.entrypoint = entrypoint
    if result.ok then
        result.opened = open_initialized_project(result.destination, opts)
        notify_user(
            notify,
            ("Initialized Typst template in %s"):format(result.destination)
        )
    else
        notify_user(
            notify,
            ("Could not initialize Typst template: %s"):format(
                result.error or result.reason
            ),
            vim.log.levels.ERROR
        )
    end
    return result
end

local function command_for(template, destination, opts)
    local command =
        vim.list_extend(util.command_prefix(config.unsafe_get().executable), {
            "init",
        })

    for _, arg in ipairs(opts.extra_args or {}) do
        command[#command + 1] = arg
    end

    command[#command + 1] = template
    if destination and destination ~= "" then
        command[#command + 1] = destination
    end
    return command
end

--- Initialize a new Typst project from a template.
---@param opts? table Template init options including template spec, destination, select, and overwrite.
---@param callback? fun(result:table) Callback invoked when provider-backed init completes.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table|nil result Init result, pending provider handle, or nil when selection is canceled.
function M.init(opts, callback, notify)
    opts = opts or {}
    local template = vim.trim(opts.template or opts.args or "")
    if template == "" then
        if opts.select then
            local records = M.templates(opts)
            if #records > 0 then
                vim.ui.select(records, {
                    prompt = "Typst template",
                    format_item = function(item)
                        return ("%s  %s"):format(
                            item.spec,
                            item.description or ""
                        )
                    end,
                }, function(item)
                    if item then
                        local next_opts = vim.tbl_extend(
                            "force",
                            opts,
                            { template = item.spec, select = false }
                        )
                        M.init(next_opts, callback, notify)
                    end
                end)
                return {
                    ok = true,
                    pending = true,
                    reason = "selecting_template",
                    count = #records,
                }
            end
        end
        return {
            ok = false,
            reason = "missing_template",
            message = "No Typst template was provided",
        }
    end

    local provider_result = provider_init(opts, callback)
    if provider_result ~= nil then
        return provider_result
    end

    local destination =
        destination_for(template, opts.directory or opts.destination)
    if opts.offline or opts.copy then
        return init_from_cache(template, destination, opts, notify)
    end

    local command = command_for(template, destination, opts)
    local result = {
        ok = true,
        pending = true,
        template = template,
        destination = destination,
        command = command,
    }

    notify_user(notify, ("Initializing Typst template %s"):format(template))
    operation.attach(result, "template-init", command, {
        cwd = vim.fn.getcwd(),
        text = true,
        detach = false,
    }, {
        on_finish = function(exit)
            if async.cancelled(result) then
                return
            end
            result.pending = false
            result.code = exit.code
            result.stdout = exit.stdout
            result.stderr = exit.stderr
            result.ok = exit.code == 0
            if result.ok then
                result.opened = open_initialized_project(destination, opts)
            end
            log.add(result.ok and "info" or "error", "typst init finished", {
                template = template,
                destination = destination,
                code = exit.code,
            })
            notify_user(
                notify,
                result.ok and ("Initialized Typst template %s"):format(template)
                    or "Typst template initialization failed",
                result.ok and vim.log.levels.INFO or vim.log.levels.ERROR
            )
            if callback then
                callback(result)
            end
        end,
    })

    return result
end

return M
