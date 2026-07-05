local operation = require("typst.core.operation")
local log = require("typst.core.log")
local output_ownership = require("typst.resources.outputs")
local project_registry = require("typst.project")
local project_store = require("typst.project.store")
local project_services = require("typst.project.services")
local status = require("typst.ui.status")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local M = {}

local DEFAULT_LIMITS = {
    max_depth = 6,
    max_logs = 80,
    max_operations = 80,
    max_projects = 25,
    max_retained = 80,
    max_telemetry_entries = 200,
}

local function limit(opts, name)
    local value = tonumber(opts[name])
    if value == nil then
        return DEFAULT_LIMITS[name]
    end
    return math.max(0, math.floor(value))
end

local function limits_for(opts)
    return {
        max_depth = limit(opts, "max_depth"),
        max_logs = limit(opts, "max_logs"),
        max_operations = limit(opts, "max_operations"),
        max_projects = limit(opts, "max_projects"),
        max_retained = limit(opts, "max_retained"),
        max_telemetry_entries = limit(opts, "max_telemetry_entries"),
    }
end

local function add(findings, code, message, fields)
    findings[#findings + 1] = vim.tbl_extend("force", {
        code = code,
        message = message,
    }, fields or {})
end

local function check_project_buffers(findings, projects)
    local owners = {}
    for key, project in pairs(projects) do
        for bufnr in pairs(project.bufs or {}) do
            owners[bufnr] = owners[bufnr] or {}
            owners[bufnr][#owners[bufnr] + 1] = key

            if not vim.api.nvim_buf_is_valid(bufnr) then
                add(
                    findings,
                    "invalid_project_buffer",
                    "project owns an invalid buffer",
                    { bufnr = bufnr, project = key }
                )
            end

            local attached = project_registry.get(bufnr)
            if attached ~= project then
                add(
                    findings,
                    "buffer_registry_mismatch",
                    "attached buffer does not resolve back to owning project",
                    { bufnr = bufnr, project = key }
                )
            end
        end
    end

    for bufnr, keys in pairs(owners) do
        if #keys > 1 then
            add(
                findings,
                "buffer_multiple_projects",
                "buffer belongs to more than one project",
                { bufnr = bufnr, projects = keys }
            )
        end
    end
end

local function check_buffer_mappings(findings, projects)
    for bufnr, key in pairs(project_store.buffers()) do
        local project = projects[key]
        if not project then
            add(
                findings,
                "buffer_mapping_missing_project",
                "buffer mapping points at a missing project",
                { bufnr = bufnr, project = key }
            )
        else
            if not vim.api.nvim_buf_is_valid(bufnr) then
                add(
                    findings,
                    "invalid_mapped_buffer",
                    "registry maps an invalid buffer to a project",
                    { bufnr = bufnr, project = key }
                )
            end
            if not (project.bufs or {})[bufnr] then
                add(
                    findings,
                    "buffer_mapping_missing_reverse_owner",
                    "buffer registry map is not mirrored by project.bufs",
                    { bufnr = bufnr, project = key }
                )
            end
        end
    end
end

local function check_project_resources(findings, projects)
    for key, project in pairs(projects) do
        local services = project_services.ensure(project)
        if not services then
            add(
                findings,
                "project_services_missing",
                "project services are unavailable",
                { project = key }
            )
            goto continue
        end
        local compiler = services.compiler or {}
        local operations = services.operations or {}
        if
            next(project.bufs or {}) == nil
            and project_services.has_active_resources(project) == false
            and (
                compiler.process
                or compiler.watcher
                or compiler.stopping_compile
                or next(operations.active_by_id or {}) ~= nil
                or next(operations.retained_by_id or {}) ~= nil
            )
        then
            add(
                findings,
                "unowned_project_resource",
                "project has resource fields but active-resource check is false",
                { project = key }
            )
        end
        ::continue::
    end
end

local function check_operations(findings)
    for id, record in pairs(operation.active()) do
        if record.state == "finished" then
            add(
                findings,
                "finished_operation_active",
                "finished operation remains in active registry",
                { operation = id, kind = record.kind }
            )
        end
    end
    for id, record in pairs(operation.retained()) do
        if record.state ~= "orphaned-retained" then
            add(
                findings,
                "invalid_retained_operation",
                "retained operation is not marked orphaned-retained",
                { operation = id, kind = record.kind, state = record.state }
            )
        end
    end
end

local function check_leases(findings)
    for key, lease in pairs(output_ownership.active()) do
        if type(lease.owner) ~= "table" or not lease.owner.kind then
            add(
                findings,
                "lease_missing_owner",
                "path lease has no owner metadata",
                { path = lease.path, key = key }
            )
        end
        if
            type(lease.owner) == "table"
            and type(lease.owner.project_key) == "string"
            and not project_store.get(lease.owner.project_key)
        then
            add(
                findings,
                "lease_unknown_project",
                "path lease references a project that is no longer registered",
                {
                    path = lease.path,
                    key = key,
                    project = lease.owner.project_key,
                    owner_kind = lease.owner.kind,
                }
            )
        end
    end
end

local function check_diagnostic_namespaces(findings, projects)
    local seen = {}
    for key, project in pairs(projects) do
        for source, namespace in pairs(project.diagnostics_namespaces or {}) do
            local previous = seen[namespace]
            if previous then
                add(
                    findings,
                    "diagnostic_namespace_shared",
                    "diagnostic namespace is shared by multiple project sources",
                    {
                        namespace = namespace,
                        project = key,
                        source = source,
                        previous = previous,
                    }
                )
            else
                seen[namespace] = { project = key, source = source }
            end
        end
    end
end

local function check_follow_buffer_autocmds(findings)
    local ok, runtime_setup = pcall(require, "typst.runtime.setup")
    if not ok or runtime_setup.is_setup() then
        return
    end

    local autocmd_ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
        group = "typst_nvim_preview_follow_buffer",
    })
    if autocmd_ok and #autocmds > 0 then
        add(
            findings,
            "follow_buffer_autocmd_after_reset",
            "follow-buffer autocmds remain after runtime setup was reset",
            { autocmds = #autocmds }
        )
    end
end

function M.check_invariants()
    local findings = {}
    ---@type table<string, TypstProject>
    local projects = project_store.all()

    check_buffer_mappings(findings, projects)
    check_project_buffers(findings, projects)
    check_project_resources(findings, projects)
    check_operations(findings)
    check_leases(findings)
    check_diagnostic_namespaces(findings, projects)
    check_follow_buffer_autocmds(findings)
    return {
        ok = #findings == 0,
        findings = findings,
        errors = findings,
        warnings = {},
        projects = vim.tbl_count(projects),
        attached_buffers = vim.tbl_count(project_store.buffers()),
        active_operations = vim.tbl_count(operation.active()),
        retained_operations = vim.tbl_count(operation.retained()),
        active_leases = vim.tbl_count(output_ownership.active()),
    }
end

function M.telemetry()
    return telemetry.snapshot()
end

function M.telemetry_report()
    return telemetry.report()
end

function M.reset_telemetry()
    telemetry.reset()
end

local function replace_path(value, path, token)
    if type(path) ~= "string" or #path <= 1 then
        return value
    end

    value = value:gsub(vim.pesc(path), token)
    local ok, encoded = pcall(vim.uri_encode, path)
    if ok and type(encoded) == "string" and encoded ~= "" then
        value = value:gsub(vim.pesc(encoded), token)
    end
    return value
end

local function collect_redaction_paths(opts)
    local paths = {}
    local seen = {}

    local function add(path, token)
        if type(path) ~= "string" or #path <= 1 then
            return
        end
        local normalized = util.normalize(path)
        if seen[normalized] then
            return
        end
        seen[normalized] = true
        paths[#paths + 1] = {
            path = normalized,
            token = token or "<path>",
        }
    end

    for _, item in ipairs(opts.redact_paths or {}) do
        if type(item) == "table" then
            add(item.path, item.token)
        else
            add(item, "<path>")
        end
    end

    add(vim.fn.getcwd(), "<cwd>")

    local project_index = 0
    for _, project in pairs(project_store.all()) do
        if type(project.root) == "string" then
            project_index = project_index + 1
            add(project.root, ("<project:%d>"):format(project_index))
        end
    end

    local ok_config, config = pcall(require, "typst.config")
    if ok_config then
        local cfg = config.unsafe_get()
        add(cfg.output_dir, "<output>")
    end

    add(vim.fn.stdpath("cache"), "<cache>")
    add(vim.fn.stdpath("state"), "<state>")
    add(vim.fn.stdpath("data"), "<data>")
    add(vim.fn.stdpath("config"), "<config>")
    add(vim.uv.os_homedir(), "~")
    table.sort(paths, function(left, right)
        return #left.path > #right.path
    end)
    return paths
end

local function with_redaction_paths(opts)
    if opts._redaction_paths then
        return opts
    end
    local out = vim.tbl_extend("force", opts or {}, {})
    out._redaction_paths = collect_redaction_paths(out)
    return out
end

local function redact_string(value, opts)
    if opts.redact == false then
        return value
    end

    for _, entry in ipairs(opts._redaction_paths or {}) do
        value = replace_path(value, entry.path, entry.token)
    end
    return value
end

local function redact_value(value, opts, depth, seen)
    local limits = opts._limits or DEFAULT_LIMITS
    local kind = type(value)
    if kind == "string" then
        return redact_string(value, opts)
    end
    if kind == "function" or kind == "userdata" or kind == "thread" then
        return ("<%s>"):format(kind)
    end
    if kind ~= "table" then
        return value
    end
    if depth > limits.max_depth then
        return "<max depth>"
    end
    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true

    local out = {}
    for key, child in pairs(value) do
        local safe_key
        if type(key) == "string" then
            safe_key = redact_string(key, opts)
        elseif type(key) == "number" then
            safe_key = key
        else
            safe_key = tostring(key)
        end
        out[safe_key] = redact_value(child, opts, depth + 1, seen)
    end
    seen[value] = nil
    return out
end

local function tail(values, max_items)
    local out = {}
    max_items = max_items or 80
    local first = math.max(1, #values - max_items + 1)
    for index = first, #values do
        out[#out + 1] = values[index]
    end
    return out
end

local function sorted_table_keys(value)
    local keys = vim.tbl_keys(value or {})
    table.sort(keys, function(left, right)
        return tostring(left) < tostring(right)
    end)
    return keys
end

local function capped_map(value, max_items)
    local out = {}
    local keys = sorted_table_keys(value)
    for index = 1, math.min(#keys, max_items) do
        local key = keys[index]
        out[key] = value[key]
    end
    return out, math.max(0, #keys - max_items)
end

local function capped_list(value, max_items)
    local out = {}
    local count = type(value) == "table" and #value or 0
    for index = 1, math.min(count, max_items) do
        out[#out + 1] = value[index]
    end
    return out, math.max(0, count - max_items)
end

local function capped_collection(value, max_items, depth, seen)
    if type(value) ~= "table" then
        return value, 0
    end
    if depth > 4 then
        return "<max telemetry depth>", 1
    end
    seen = seen or {}
    if seen[value] then
        return "<cycle>", 1
    end
    seen[value] = true

    local out = {}
    local truncated = 0
    local keys = sorted_table_keys(value)
    for index = 1, math.min(#keys, max_items) do
        local key = keys[index]
        local child, child_truncated =
            capped_collection(value[key], max_items, depth + 1, seen)
        out[key] = child
        truncated = truncated + child_truncated
    end
    truncated = truncated + math.max(0, #keys - max_items)
    if #keys > max_items then
        out._truncated_count = #keys - max_items
    end

    seen[value] = nil
    return out, truncated
end

local function maybe_call(fn, fallback)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return fallback
        or {
            ok = false,
            reason = "collection_failed",
            message = tostring(result),
        }
end

local function project_reports(opts)
    local reports = {}
    for key, project in pairs(project_store.all()) do
        reports[#reports + 1] = {
            key = key,
            status = maybe_call(function()
                return status.project_snapshot(project)
            end, nil),
            services = maybe_call(function()
                return project_services.snapshot(project)
            end, nil),
        }
    end
    table.sort(reports, function(left, right)
        return tostring(left.key) < tostring(right.key)
    end)
    reports, opts._truncated.projects =
        capped_list(reports, (opts._limits or DEFAULT_LIMITS).max_projects)
    return redact_value(reports, opts, 0, {})
end

local function nvim_version()
    local version = vim.version()
    return {
        major = version.major,
        minor = version.minor,
        patch = version.patch,
        prerelease = version.prerelease,
    }
end

local function typst_version()
    local executable = "typst"
    local ok_config, config = pcall(require, "typst.config")
    if ok_config then
        executable = config.unsafe_get().executable or executable
    end

    local command = util.command_prefix(executable)
    command[#command + 1] = "--version"
    local ok, stdout = pcall(vim.fn.systemlist, command)
    return {
        executable = executable,
        command = command,
        code = ok and vim.v.shell_error or nil,
        stdout = ok and stdout or nil,
        error = ok and nil or tostring(stdout),
    }
end

---Build a redacted support artifact for bug reports.
---@param opts? {redact?:boolean, redact_paths?:table, max_depth?:integer, max_logs?:integer, max_operations?:integer, max_projects?:integer, max_retained?:integer, max_telemetry_entries?:integer, pretty?:boolean} Bug-report controls.
---@return any data Structured report data after redaction/truncation.
function M.bug_report_data(opts)
    opts = with_redaction_paths(opts or {})
    opts._limits = limits_for(opts)
    opts._truncated = {}
    local invariants = M.check_invariants()
    local cache_stats = maybe_call(function()
        return require("typst.core.cache_registry").stats()
    end, nil)
    local active_operations, active_truncated =
        capped_map(operation.active(), opts._limits.max_operations)
    local retained_operations, retained_truncated =
        capped_map(operation.retained(), opts._limits.max_retained)
    opts._truncated.active_operations = active_truncated
    opts._truncated.retained_operations = retained_truncated
    local telemetry_snapshot, telemetry_snapshot_truncated = capped_collection(
        telemetry.snapshot(),
        opts._limits.max_telemetry_entries,
        0
    )
    local telemetry_report, telemetry_report_truncated = capped_collection(
        telemetry.report(),
        opts._limits.max_telemetry_entries,
        0
    )
    opts._truncated.telemetry_entries = telemetry_snapshot_truncated
        + telemetry_report_truncated

    local data = {
        schema = "typst.nvim.bug_report.v1",
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        redacted = opts.redact ~= false,
        limits = opts._limits,
        truncated = opts._truncated,
        api = maybe_call(function()
            return require("typst").version()
        end, { api = 1, api_version = 1 }),
        environment = {
            nvim = nvim_version(),
            os = vim.uv.os_uname(),
            cwd = vim.fn.getcwd(),
            typst = typst_version(),
        },
        projects = project_reports(opts),
        invariants = invariants,
        operations = {
            active = active_operations,
            retained = retained_operations,
        },
        output_leases = output_ownership.active(),
        cache = cache_stats,
        telemetry = {
            snapshot = telemetry_snapshot,
            report = telemetry_report,
        },
        log_file = log.file_state(),
        logs = tail(log.entries(), opts._limits.max_logs),
    }

    return redact_value(data, opts, 0, {})
end

local function pretty_json(encoded)
    local lines = {}
    local current = {}
    local indent = 0
    local in_string = false
    local escaped = false

    local function append(text)
        current[#current + 1] = text
    end

    local function push()
        if #current > 0 then
            lines[#lines + 1] = table.concat(current)
            current = {}
        end
    end

    local function padding()
        return string.rep("  ", indent)
    end

    for index = 1, #encoded do
        local char = encoded:sub(index, index)
        if in_string then
            append(char)
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == '"' then
                in_string = false
            end
        elseif char == '"' then
            in_string = true
            append(char)
        elseif char == "{" or char == "[" then
            append(char)
            push()
            indent = indent + 1
            append(padding())
        elseif char == "}" or char == "]" then
            push()
            indent = math.max(0, indent - 1)
            append(padding() .. char)
        elseif char == "," then
            append(char)
            push()
            append(padding())
        elseif char == ":" then
            append(": ")
        elseif not char:match("%s") then
            append(char)
        end
    end
    push()
    return lines
end

local function encode_bug_report(data, opts)
    local ok, encoded = pcall(vim.json.encode, data)
    if ok then
        if opts and opts.pretty == false then
            return { encoded }
        end
        return pretty_json(encoded)
    end
    return nil,
        {
            ok = false,
            reason = "json_encode_failed",
            message = tostring(encoded),
            data = data,
        }
end

---Return JSON lines for a bug-report artifact.
---@param opts? {redact?:boolean, redact_paths?:table, max_depth?:integer, max_logs?:integer, max_operations?:integer, max_projects?:integer, max_retained?:integer, max_telemetry_entries?:integer, pretty?:boolean} Bug-report controls.
---@return string[]|nil lines JSON report lines.
---@return table|nil error Structured encode failure.
function M.bug_report_lines(opts)
    local data = M.bug_report_data(opts)
    return encode_bug_report(data, opts or {})
end

---Create a bug-report artifact, optionally writing/opening it.
---@param opts? {open?:boolean, path?:string, redact?:boolean, redact_paths?:table, max_depth?:integer, max_logs?:integer, max_operations?:integer, max_projects?:integer, max_retained?:integer, max_telemetry_entries?:integer, pretty?:boolean} Controls.
---@return table result Bug-report result with `data`, `lines`, and optional buffer/path.
function M.bug_report(opts)
    opts = opts or {}
    local data_opts = {
        redact = opts.redact,
        redact_paths = opts.redact_paths,
        max_depth = opts.max_depth,
        max_logs = opts.max_logs,
        max_operations = opts.max_operations,
        max_projects = opts.max_projects,
        max_retained = opts.max_retained,
        max_telemetry_entries = opts.max_telemetry_entries,
        pretty = opts.pretty,
    }
    local data = M.bug_report_data(data_opts)
    local encode_opts = {
        redact = opts.redact ~= false,
        max_depth = opts.max_depth,
        max_logs = opts.max_logs,
        max_operations = opts.max_operations,
        max_projects = opts.max_projects,
        max_retained = opts.max_retained,
        max_telemetry_entries = opts.max_telemetry_entries,
        pretty = opts.pretty,
    }
    local lines, encode_error = encode_bug_report(data, encode_opts)
    if not lines then
        encode_error = encode_error
            or {
                ok = false,
                reason = "json_encode_failed",
                message = "Failed to encode bug report",
            }
        encode_error.redacted = opts.redact ~= false
        return encode_error
    end
    local result = {
        ok = true,
        data = data,
        lines = lines,
        redacted = opts.redact ~= false,
    }

    if type(opts.path) == "string" and opts.path ~= "" then
        local path = vim.fn.fnamemodify(opts.path, ":p")
        local ok, write_result = pcall(vim.fn.writefile, lines, path)
        if not ok or write_result ~= 0 then
            return {
                ok = false,
                reason = "write_failed",
                message = ok and ("writefile returned " .. tostring(
                    write_result
                )) or tostring(write_result),
                path = path,
                data = data,
                lines = lines,
            }
        end
        result.path = path
    end

    if opts.open == true then
        result.buffer = require("typst.ui.reports").open_scratch_buffer(
            "typst.nvim bug report",
            "json",
            lines
        )
    end

    return result
end

return M
