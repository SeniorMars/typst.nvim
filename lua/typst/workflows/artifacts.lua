local config = require("typst.config")
local async = require("typst.core.async")
local events = require("typst.core.events")
local log = require("typst.core.log")
local open_helper = require("typst.core.open")
local operation = require("typst.core.operation")
local output_path_util = require("typst.compiler.output_path")
local path_leases = require("typst.core.path_leases")
local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local artifacts_service = require("typst.project.services.artifacts")
local compiler_service = require("typst.project.services.compiler")
local util = require("typst.core.util")

local M = {}

-- Export/artifact ownership tracking.
--
-- Exports can be produced by Typst itself or custom providers, so this module
-- records which outputs typst.nvim created before cleanups are allowed to remove
-- them.
local EXPORT_HASH_MAX_BYTES = 1024 * 1024

local known_formats = {
    bundle = true,
    html = true,
    pdf = true,
    png = true,
    svg = true,
}

local notify_user = require("typst.core.notify").user

local function output_format_from_name(output_name)
    if type(output_name) ~= "string" or output_name == "" then
        return nil
    end

    local ext = vim.fn.fnamemodify(output_name, ":e")
    if ext ~= "" then
        return ext
    end
    return nil
end

local function spec_format(spec, fallback_format)
    return spec.format
        or spec.output_format
        or output_format_from_name(spec.output_name or spec.name)
        or fallback_format
        or "pdf"
end

local function normalize_spec(value, fallback_format)
    if type(value) == "string" then
        return { format = value }
    end
    if type(value) == "table" then
        local spec = vim.deepcopy(value)
        spec.format = spec_format(spec, fallback_format)
        return spec
    end
    return { format = fallback_format or "pdf" }
end

local function specs_for(opts)
    local cfg = config.unsafe_get()
    local exports = cfg.exports or {}
    local profiles = exports.profiles or exports
    local requested_profile = opts.profile or opts.name
    local requested = requested_profile or opts.format

    if requested_profile and profiles[requested_profile] ~= nil then
        local profile = profiles[requested_profile]
        if util.is_list(profile) then
            return vim.tbl_map(normalize_spec, profile), requested_profile
        end
        return { normalize_spec(profile) }, requested_profile
    end

    if
        requested
        and profiles[requested] ~= nil
        and not known_formats[requested]
    then
        local profile = profiles[requested]
        if util.is_list(profile) then
            return vim.tbl_map(normalize_spec, profile), requested
        end
        return { normalize_spec(profile) }, requested
    end

    if opts.outputs and util.is_list(opts.outputs) then
        return vim.tbl_map(normalize_spec, opts.outputs), requested
    end

    if opts.format or (requested and known_formats[requested]) then
        return { normalize_spec(opts, opts.format or requested) }, requested
    end

    local default_profile = exports.default
    if default_profile and profiles[default_profile] then
        local profile = profiles[default_profile]
        if util.is_list(profile) then
            return vim.tbl_map(normalize_spec, profile), default_profile
        end
        return { normalize_spec(profile) }, default_profile
    end

    return { normalize_spec(opts, cfg.output_format or "pdf") }, requested
end

local function output_path(project, spec)
    local run_config = config.snapshot()
    run_config.output_format =
        spec_format(spec, run_config.output_format or "pdf")
    run_config.output_name = spec.output_name
        or spec.name
        or run_config.output_name
    run_config.output_dir = spec.output_dir or run_config.output_dir
    return output_path_util.output_path(project, run_config)
end

local function path_key(path)
    return util.path_key(util.canonical(path))
end

local function file_signature(path)
    local stat = path and vim.uv.fs_stat(path) or nil
    if not stat then
        return nil
    end

    local mtime = stat.mtime or {}
    return table.concat({
        stat.type or "",
        tostring(stat.size or 0),
        tostring(mtime.sec or 0),
        tostring(mtime.nsec or 0),
    }, ":")
end

local function artifact_state(project)
    local state = artifacts_service.get(project) or {}
    state.items = state.items or {}
    state.owned = state.owned or {}
    return state
end

local function path_set(paths)
    local set = {}
    for _, path in ipairs(paths or {}) do
        if type(path) == "string" and path ~= "" then
            set[path_key(path)] = true
        end
    end
    return set
end

local function provider_label(provider)
    if type(provider) == "string" then
        return provider
    end
    if type(provider) == "function" then
        return "callback"
    end
    if type(provider) == "table" then
        return provider.name or "table"
    end
    return nil
end

local function preview_export_metadata(opts, artifact)
    if opts.preview_export ~= true then
        return nil
    end

    return {
        mode = opts.preview_export_mode,
        target = opts.preview_target,
        profile = opts.profile,
        provider = provider_label(opts.provider),
        output_format = opts.format or artifact.format,
        output_name = opts.output_name,
        output_dir = opts.output_dir,
        extra_args = vim.deepcopy(opts.extra_args or {}),
    }
end

local function public_artifact_copy(artifact)
    local copy = {}
    for field, value in pairs(artifact or {}) do
        if field ~= "operation" and field ~= "handle" then
            local ok, copied = pcall(vim.deepcopy, value)
            copy[field] = ok and copied or nil
        end
    end
    return copy
end

local function file_hash(path, size)
    -- Hash only small artifacts. Large PDFs are identified by size/mtime so
    -- status checks do not turn into full-file reads.
    if
        not path
        or type(size) ~= "number"
        or size > EXPORT_HASH_MAX_BYTES
        or vim.fn.exists("*sha256") ~= 1
    then
        return nil
    end

    local ok, lines = pcall(vim.fn.readfile, path, "b")
    if not ok or type(lines) ~= "table" then
        return nil
    end
    return vim.fn.sha256(table.concat(lines, "\n"))
end

local function file_fingerprint(path)
    local stat = path and vim.uv.fs_stat(path) or nil
    if not stat then
        return nil
    end

    local mtime = stat.mtime or {}
    local signature = file_signature(path)
    return {
        signature = signature,
        size = stat.size or 0,
        mtime_sec = mtime.sec or 0,
        mtime_nsec = mtime.nsec or 0,
        hash = file_hash(path, stat.size or 0),
    }
end

--- Return a content-aware fingerprint for an artifact path.
---@param path? string Artifact path to inspect.
---@return table? fingerprint File signature/hash metadata, or nil when missing.
function M.fingerprint(path)
    return file_fingerprint(path)
end

--- Record that typst.nvim produced an artifact for later safe cleanup.
---@param project table Project state whose artifact service is updated.
---@param artifact table Artifact metadata; must include `path`.
---@return table? record Stored ownership record, or nil when the artifact is invalid/missing.
function M.record_owned(project, artifact)
    if type(project) ~= "table" or type(artifact) ~= "table" then
        return nil
    end
    local path = artifact.path
    if type(path) ~= "string" or path == "" then
        return nil
    end

    local fingerprint = artifact.fingerprint or file_fingerprint(path)
    if not fingerprint then
        return nil
    end

    local key = path_key(path)
    local state = artifact_state(project)
    state.owned[key] = {
        path = path,
        canonical_path = key,
        project_key = project.key,
        producer = artifact.producer or artifact.format or "artifact",
        generation = artifact.generation,
        created_at = artifact.created_at,
        used_at = artifact.used_at,
        preview_export = artifact.preview_export and vim.deepcopy(
            artifact.preview_export
        ) or nil,
        created_signature = fingerprint.signature,
        created_hash = fingerprint.hash,
    }
    artifacts_service.set(project, { owned = state.owned })
    return state.owned[key]
end

--- Return the ownership record for an artifact path.
---@param project table Project state whose artifact service is inspected.
---@param path string Artifact path to look up.
---@return table? record Stored ownership record, if present.
function M.owned_record(project, path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return (artifact_state(project).owned or {})[path_key(path)]
end

--- Check whether an owned artifact path still matches its recorded contents.
---@param project table Project state whose artifact service is inspected.
---@param path string Artifact path to validate.
---@param opts? table Validation options.
---@return boolean ok True when the path is still owned and unchanged enough to clean.
---@return string? reason Failure reason when ownership/currentness check fails.
---@return table? record Ownership record for the path.
function M.owned_current(project, path, opts)
    opts = opts or {}
    local record = M.owned_record(project, path)
    if not record then
        return false, "unowned_output"
    end

    local fingerprint = file_fingerprint(path)
    if not fingerprint then
        return false, "missing_output", record
    end
    if record.created_signature ~= fingerprint.signature then
        if
            record.created_hash
            and fingerprint.hash
            and record.created_hash == fingerprint.hash
        then
            return true, nil, record
        end
        return false, "changed_output", record
    end
    return true, nil, record
end

local function verify_artifact(path, before, started_at_sec)
    -- Coarse filesystems can leave a signature unchanged after a fast export.
    -- A hash match or fresh mtime is enough to avoid a false stale-output error.
    local fingerprint = file_fingerprint(path)
    if not fingerprint then
        return false, "missing_output"
    end
    if before and before.signature == fingerprint.signature then
        if
            before.hash
            and fingerprint.hash
            and before.hash ~= fingerprint.hash
        then
            return true, nil, fingerprint.signature
        end
        if
            not before.hash
            and not fingerprint.hash
            and type(started_at_sec) == "number"
            and (fingerprint.mtime_sec or 0) >= started_at_sec - 1
        then
            return true, nil, fingerprint.signature, "mtime"
        end
        return false, "stale_output"
    end
    return true, nil, fingerprint.signature
end

local function terminal_result(result)
    return type(result) ~= "table" or result.pending ~= true
end

local function add_arg(args, flag, value)
    if value == nil or value == false then
        return
    end
    args[#args + 1] = flag
    if value ~= true then
        args[#args + 1] = tostring(value)
    end
end

local function add_list_arg(args, flag, value)
    if value == nil then
        return
    end
    if type(value) == "table" then
        value = table.concat(value, ",")
    end
    add_arg(args, flag, value)
end

local function add_repeated_arg(args, flag, value)
    if value == nil then
        return
    end
    if type(value) == "table" then
        for _, item in ipairs(value) do
            add_arg(args, flag, item)
        end
        return
    end
    add_arg(args, flag, value)
end

local function add_input_args(args, inputs)
    if inputs == nil then
        return
    end
    if type(inputs) == "string" then
        add_arg(args, "--input", inputs)
        return
    end
    if type(inputs) ~= "table" then
        return
    end
    if util.is_list(inputs) then
        for _, item in ipairs(inputs) do
            add_arg(args, "--input", item)
        end
        return
    end

    local keys = vim.tbl_keys(inputs)
    table.sort(keys)
    for _, key in ipairs(keys) do
        local value = inputs[key]
        if value ~= nil then
            add_arg(args, "--input", ("%s=%s"):format(key, tostring(value)))
        end
    end
end

local function replace_placeholders(value, ctx)
    return (
        value:gsub("{([%w_]+)}", function(key)
            return ctx[key] or ""
        end)
    )
end

local function command_context(project, spec, path, profile)
    local output_dir = vim.fn.fnamemodify(path, ":h")
    local output_name = vim.fn.fnamemodify(path, ":t")
    local format = spec_format(spec, config.unsafe_get().output_format or "pdf")
    return {
        root = project.root,
        main = project.main,
        input = project.main,
        output = path,
        output_dir = output_dir,
        output_name = output_name,
        format = format,
        output_format = format,
        typst_format = spec.typst_format or spec.compile_format or format,
        profile = profile or "",
        name = spec.name or spec.output_name or "",
    }
end

local function render_command(command, ctx)
    local rendered = util.command_prefix(command)
    for index, arg in ipairs(rendered) do
        rendered[index] = replace_placeholders(arg, ctx)
    end
    return rendered
end

local function command_cwd(project, spec, ctx)
    if type(spec.cwd) == "string" and spec.cwd ~= "" then
        return util.resolve_path(
            replace_placeholders(spec.cwd, ctx),
            project.root
        )
    end
    return project.root
end

local function typst_command_for(project, spec, path)
    local cfg = config.unsafe_get()
    local args = vim.list_extend(util.command_prefix(cfg.executable), {
        "compile",
        "--root",
        project.root,
        "--format",
        spec.typst_format
            or spec.compile_format
            or spec.format
            or cfg.output_format
            or "pdf",
    })

    for _, arg in ipairs(cfg.compile.extra_args or {}) do
        args[#args + 1] = arg
    end
    for _, arg in ipairs(spec.extra_args or {}) do
        args[#args + 1] = arg
    end

    add_input_args(args, spec.inputs or spec.input)
    add_repeated_arg(args, "--font-path", spec.font_paths or spec.font_path)
    add_arg(args, "--ignore-system-fonts", spec.ignore_system_fonts == true)
    add_arg(args, "--ignore-embedded-fonts", spec.ignore_embedded_fonts == true)
    add_arg(args, "--package-path", spec.package_path)
    add_arg(args, "--package-cache-path", spec.package_cache_path)
    add_arg(args, "--creation-timestamp", spec.creation_timestamp)
    add_arg(args, "--pretty", spec.pretty == true)
    add_list_arg(args, "--pages", spec.pages)
    add_list_arg(
        args,
        "--pdf-standard",
        spec.pdf_standard or spec.pdf_standards
    )
    add_arg(args, "--no-pdf-tags", spec.no_pdf_tags == true)
    add_arg(args, "--ppi", spec.ppi)
    add_arg(args, "--jobs", spec.jobs)
    add_list_arg(args, "--features", spec.features)
    add_arg(args, "--diagnostic-format", spec.diagnostic_format)
    add_arg(args, "--timings", spec.timings)

    args[#args + 1] = project.main
    args[#args + 1] = path
    return args
end

local function command_for(project, spec, path, profile)
    if spec.command ~= nil then
        return render_command(
            spec.command,
            command_context(project, spec, path, profile)
        ),
            "command"
    end
    return typst_command_for(project, spec, path), "typst"
end

local function register_artifact(project, artifact, opts)
    opts = opts or {}
    local state = artifact_state(project)
    local artifacts = state.items or {}
    local key = path_key(artifact.path)
    local now = os.time()
    artifact.canonical_path = key
    artifact.producer = artifact.producer or opts.producer or "export"
    artifact.preview_export = artifact.preview_export
        or preview_export_metadata(opts, artifact)
    for index, existing in ipairs(artifacts) do
        if existing.path and path_key(existing.path) == key then
            artifact.created_at = artifact.created_at
                or existing.created_at
                or now
            artifact.used_at = now
            M.record_owned(project, {
                path = artifact.path,
                producer = artifact.producer,
                generation = artifact.generation,
                created_at = artifact.created_at,
                used_at = artifact.used_at,
                preview_export = artifact.preview_export,
            })
            artifacts[index] = artifact
            artifacts_service.set(project, {
                items = artifacts,
                last = artifact,
                output = artifact.format == "pdf"
                        and opts.update_compiler_output ~= false
                        and artifact.path
                    or state.output,
            })
            if
                artifact.format == "pdf"
                and opts.update_compiler_output ~= false
            then
                compiler_service.set(project, { output = artifact.path })
            end
            return
        end
    end

    artifact.created_at = artifact.created_at or now
    artifact.used_at = now
    M.record_owned(project, {
        path = artifact.path,
        producer = artifact.producer,
        generation = artifact.generation,
        created_at = artifact.created_at,
        used_at = artifact.used_at,
        preview_export = artifact.preview_export,
    })
    artifacts[#artifacts + 1] = artifact
    artifacts_service.set(project, {
        items = artifacts,
        last = artifact,
        output = artifact.format == "pdf"
                and opts.update_compiler_output ~= false
                and artifact.path
            or state.output,
    })
    if artifact.format == "pdf" and opts.update_compiler_output ~= false then
        compiler_service.set(project, { output = artifact.path })
    end
end

local function artifact_event_payload(artifact)
    return {
        id = artifact.id,
        format = artifact.format,
        path = artifact.path,
        canonical_path = artifact.canonical_path,
        profile = artifact.profile,
        command = artifact.command and vim.deepcopy(artifact.command) or nil,
        status = artifact.status,
        signature = artifact.signature,
        freshness = artifact.freshness,
        reason = artifact.reason,
        producer = artifact.producer,
        preview_export = artifact.preview_export and vim.deepcopy(
            artifact.preview_export
        ) or nil,
    }
end

local function normalize_provider_result(project, result, allowed_outputs, opts)
    if type(result) ~= "table" then
        return result
    end

    local artifacts = result.artifacts or result.outputs
    local listed = {}
    if type(artifacts) == "table" then
        for _, artifact in ipairs(artifacts) do
            if type(artifact) == "table" and artifact.path then
                listed[#listed + 1] = artifact
            end
        end
    elseif result.path then
        listed[#listed + 1] = result
    end

    for _, artifact in ipairs(listed) do
        local key = path_key(artifact.path)
        if allowed_outputs and not allowed_outputs[key] then
            return vim.tbl_extend("force", result, {
                ok = false,
                pending = false,
                reason = "undeclared_output",
                message = "Export provider returned an output path that was not reserved",
                path = artifact.path,
                allowed_outputs = vim.tbl_values(allowed_outputs),
            })
        end
    end

    for _, artifact in ipairs(listed) do
        register_artifact(project, artifact, opts)
    end

    return result
end

local function release_leases_once(leases)
    local released = false
    return function()
        if released then
            return
        end
        released = true
        path_leases.release_many(leases)
    end
end

local function preflight_planned_outputs(planned)
    for _, item in ipairs(planned or {}) do
        local parent_ok, parent_err = util.ensure_parent(item.path)
        if not parent_ok then
            return false,
                {
                    ok = false,
                    pending = false,
                    reason = "parent_create_failed",
                    message = tostring(parent_err),
                    path = item.path,
                }
        end
    end
    return true
end

local function planned_output_map(planned)
    local outputs = {}
    local paths = {}
    local records = {}
    for _, item in ipairs(planned or {}) do
        outputs[item.canonical] = item.path
        paths[#paths + 1] = item.path
        records[#records + 1] = {
            format = item.spec and item.spec.format or nil,
            path = item.path,
            canonical = item.canonical,
        }
    end
    return outputs, paths, records
end

local function provider_export(project, opts, callback, notify, planned)
    -- Reserve every declared output before invoking custom providers. Results
    -- pointing elsewhere are rejected so integrations cannot silently overwrite
    -- paths outside the user's export plan.
    local provider = providers.resolve(
        "export",
        opts.provider or (config.unsafe_get().exports or {}).provider
    )
    if provider == nil or provider == "typst" then
        return nil
    end
    local parent_ok, parent_result = preflight_planned_outputs(planned)
    if not parent_ok then
        return parent_result
    end
    local leases, lease_err = path_leases.acquire_many(planned, {
        kind = "export-provider",
        project_key = project.key,
        main = project.main,
    })
    if not leases then
        return {
            ok = false,
            pending = false,
            reason = lease_err.reason,
            message = lease_err.message,
            duplicate_output = lease_err.duplicate_output,
            active_output = lease_err.active_output or lease_err.path,
        }
    end
    local release_leases = release_leases_once(leases)
    local allowed_outputs, output_paths, output_records =
        planned_output_map(planned)
    local provider_project = providers.project_context(project)
    local primary_spec = planned[1] and planned[1].spec or {}
    local provider_opts = vim.tbl_extend("force", opts, primary_spec, {
        output_path = output_paths[1],
        output_paths = output_paths,
        planned_outputs = output_records,
        output_specs = vim.tbl_map(function(item)
            return vim.deepcopy(item.spec or {})
        end, planned),
    })
    local notified = false
    local function notify_finished(result)
        if notified or (type(result) == "table" and result.pending == true) then
            return
        end
        notified = true
        notify_user(notify, "Typst export provider finished")
    end
    local function provider_result(result)
        result = normalize_provider_result(
            project,
            result,
            allowed_outputs,
            provider_opts
        )
        if result ~= nil then
            notify_finished(result)
        end
        if terminal_result(result) then
            release_leases()
        end
        return result
    end

    local returned = provider_adapter.invoke(
        provider,
        { "export", "run" },
        provider_project,
        provider_opts,
        {
            kind = "export",
            provider_name = type(provider) == "table" and provider.name
                or "callback",
            args = { provider_project, provider_opts },
            timeout_ms = opts.timeout_ms
                or (config.unsafe_get().exports or {}).timeout_ms,
            on_result = callback,
            normalize = provider_result,
            invalid_result_message = "Export provider returned no result",
        }
    )
    if terminal_result(returned) then
        release_leases()
    end
    return returned
end

local function common_spec_provider(specs)
    local provider = nil
    local provider_count = 0
    for _, spec in ipairs(specs or {}) do
        if spec.provider ~= nil then
            provider_count = provider_count + 1
            if spec.command ~= nil then
                return nil,
                    {
                        ok = false,
                        pending = false,
                        reason = "invalid_export_spec",
                        message = "Export specs cannot set both provider and command",
                    }
            end
            if provider == nil then
                provider = spec.provider
            elseif provider ~= spec.provider then
                return nil,
                    {
                        ok = false,
                        pending = false,
                        reason = "mixed_export_providers",
                        message = "One export plan cannot mix different per-spec providers",
                    }
            end
        end
    end
    if provider ~= nil and provider_count ~= #(specs or {}) then
        return nil,
            {
                ok = false,
                pending = false,
                reason = "mixed_export_providers",
                message = "One export plan cannot mix provider-owned and built-in export specs",
            }
    end
    return provider
end

local function write_stdout_artifact(path, stdout)
    local parent_ok, parent_err = util.ensure_parent(path)
    if not parent_ok then
        return false, tostring(parent_err)
    end

    local text = stdout or ""
    local lines = vim.split(text, "\n", { plain = true })
    if text:sub(-1) == "\n" then
        table.remove(lines)
    end
    local ok, err = util.writefile_checked(lines, path)
    if not ok then
        return false, tostring(err)
    end
    return true
end

--- Export one or more Typst artifacts for a project.
---@param project table Project state whose main file should be exported.
---@param opts? table Export options, including profile, format, outputs, and provider controls.
---@param callback? fun(result:table, project:table) Callback invoked when export work completes.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table result Export plan/result with artifact records, pending state, and cancellation when async.
function M.export(project, opts, callback, notify)
    opts = opts or {}
    local specs, profile = specs_for(opts)
    local result = {
        ok = true,
        pending = true,
        profile = profile,
        artifacts = {},
        handles = {},
        operations = {},
        completed = 0,
        failed = 0,
    }
    local planned = {}
    for index, spec in ipairs(specs) do
        local path = output_path(project, spec)
        local canonical = path_key(path)
        planned[index] = {
            spec = spec,
            path = path,
            canonical = canonical,
            before_fingerprint = file_fingerprint(path),
        }
    end

    local spec_provider, spec_provider_error = common_spec_provider(specs)
    if spec_provider_error then
        return vim.tbl_extend("force", result, spec_provider_error)
    end
    local provider_opts = spec_provider ~= nil
            and vim.tbl_extend("force", opts, { provider = spec_provider })
        or opts
    local provider_result =
        provider_export(project, provider_opts, callback, notify, planned)
    if provider_result ~= nil then
        return provider_result
    end

    async.attach_result(result, {
        on_cancel = function(cancelled)
            for _, artifact in ipairs(cancelled.artifacts or {}) do
                if artifact.status == "pending" then
                    artifact.status = "cancelled"
                end
            end
        end,
    })
    local final_callback_called = false
    local function finish_export_callback()
        if final_callback_called then
            return
        end
        final_callback_called = true
        if callback then
            callback(result, providers.project_context(project))
        end
    end
    result.cancel = function(cancel_opts, callback)
        result.cancel_requested = true
        result.cancelled = true
        result.pending = #result.operations > 0
        result.ok = false
        result.state = result.pending and "cancelling" or "cancelled"
        result.reason = "cancelled"
        for _, artifact in ipairs(result.artifacts or {}) do
            if artifact.status == "pending" then
                artifact.status = result.pending and "cancelling" or "cancelled"
            end
        end

        local stopped = true
        local cancel_results = {}
        for _, artifact_operation in ipairs(result.operations or {}) do
            local ok, cancel_result =
                artifact_operation.cancel(cancel_opts or {})
            cancel_results[#cancel_results + 1] = cancel_result
            if not ok then
                stopped = false
            end
        end

        result.cancel_result = {
            stopped = stopped,
            results = cancel_results,
        }
        if type(callback) == "function" then
            callback(stopped, result.cancel_result)
        end
        if
            #result.operations == 0
            or result.completed >= #result.operations
        then
            result.pending = false
            result.state = result.orphaned and "orphaned" or "cancelled"
            finish_export_callback()
        end
        return stopped, result.cancel_result
    end

    if #specs == 0 then
        result.ok = false
        result.pending = false
        result.reason = "empty_export"
        return result
    end

    local parent_ok, parent_result = preflight_planned_outputs(planned)
    if not parent_ok then
        return vim.tbl_extend("force", result, parent_result)
    end

    local leases, lease_err = path_leases.acquire_many(planned, {
        kind = "export",
        project_key = project.key,
        main = project.main,
    })
    if not leases then
        result.ok = false
        result.pending = false
        result.reason = lease_err.reason
        result.message = lease_err.message
        result.duplicate_output = lease_err.duplicate_output
        result.active_output = lease_err.active_output or lease_err.path
        return result
    end
    for index, lease in ipairs(leases) do
        planned[index].lease = lease
    end

    notify_user(
        notify,
        ("Exporting %s artifact%s"):format(#specs, #specs == 1 and "" or "s")
    )

    for index, item in ipairs(planned) do
        local spec = item.spec
        local path = item.path
        local command, command_kind = command_for(project, spec, path, profile)
        local cwd = command_cwd(
            project,
            spec,
            command_context(project, spec, path, profile)
        )
        item.started_at_sec = os.time()
        local artifact = {
            id = ("%s:%s:%d"):format(
                project.key or project.main,
                spec.format or "pdf",
                index
            ),
            format = spec.format or "pdf",
            path = path,
            canonical_path = item.canonical,
            profile = profile,
            command = command,
            status = "pending",
            producer = spec.producer or opts.producer or command_kind,
        }
        result.artifacts[#result.artifacts + 1] = artifact

        local artifact_operation = operation.run("export", command, {
            cwd = cwd,
            text = true,
            detach = false,
        }, {
            cleanup = function()
                path_leases.release(item.lease)
            end,
            on_cancel_failed = function()
                result.orphaned = true
                result.state = "orphaned"
                result.reason = "child_orphaned"
                artifact.status = "orphaned"
            end,
        })
        artifact_operation:on_finish(function(exit)
            result.completed = result.completed + 1
            if async.cancelled(result) then
                artifact.result = exit
                local was_orphaned = exit.orphaned or exit.was_orphaned
                artifact.status = was_orphaned and "orphaned" or "cancelled"
                if was_orphaned then
                    result.orphaned = true
                    result.state = "orphaned"
                    result.reason = "child_orphaned"
                end
                if result.completed == #specs then
                    result.pending = false
                    result.state = result.orphaned and "orphaned" or "cancelled"
                    finish_export_callback()
                end
                return
            end
            artifact.result = exit
            if exit.code ~= 0 then
                artifact.status = "error"
                result.failed = result.failed + 1
                result.ok = false
            else
                local should_verify = true
                if spec.stdout == true then
                    local write_ok, write_err =
                        write_stdout_artifact(path, exit.stdout)
                    if not write_ok then
                        artifact.status = "error"
                        artifact.reason = "stdout_write_failed"
                        artifact.message = write_err
                        result.failed = result.failed + 1
                        result.ok = false
                        should_verify = false
                    end
                end
                if should_verify then
                    local verified, verify_error, signature, freshness =
                        verify_artifact(
                            path,
                            item.before_fingerprint,
                            item.started_at_sec
                        )
                    if verified then
                        artifact.status = "success"
                        artifact.signature = signature
                        artifact.freshness = freshness
                        register_artifact(project, artifact, opts)
                        events.emit(
                            "TypstArtifactCreated",
                            project,
                            artifact_event_payload(artifact)
                        )
                    else
                        artifact.status = "error"
                        artifact.reason = verify_error
                        result.failed = result.failed + 1
                        result.ok = false
                    end
                end
            end

            if result.completed == #specs then
                result.pending = false
                log.add("info", "export finished", {
                    main = project.main,
                    artifacts = #result.artifacts,
                    failed = result.failed,
                })
                if result.failed == 0 then
                    notify_user(
                        notify,
                        ("Exported %d Typst artifact%s"):format(
                            #result.artifacts,
                            #result.artifacts == 1 and "" or "s"
                        )
                    )
                else
                    notify_user(
                        notify,
                        "Typst export failed; use :TypstLog for details",
                        vim.log.levels.ERROR
                    )
                end
                finish_export_callback()
            end
        end)

        artifact.operation = artifact_operation
        artifact.handle = artifact_operation.handle
        result.operations[#result.operations + 1] = artifact_operation
        result.handles[#result.handles + 1] = artifact_operation.handle
    end

    return result
end

--- Reset artifact path leases used by export/render workflows.
function M.reset()
    path_leases.reset()
end

--- Return known artifacts for a project.
---@param project table Project state whose artifact/compiler services are queried.
---@param opts? table List options; `format` filters artifacts by extension/format.
---@return table[] artifacts Sorted artifact records.
function M.artifacts(project, opts)
    opts = opts or {}
    local artifact_state = artifacts_service.get(project) or {}
    local compiler_state = compiler_service.get(project) or {}
    local artifacts =
        vim.tbl_map(public_artifact_copy, artifact_state.items or {})
    local output = artifact_state.output or compiler_state.output
    if #artifacts == 0 and output then
        artifacts[1] = {
            id = ("%s:output"):format(project.key or project.main),
            format = vim.fn.fnamemodify(output, ":e"),
            path = output,
            status = vim.fn.filereadable(output) == 1 and "success"
                or "missing",
            producer = "compile",
        }
    end

    if opts.format then
        artifacts = vim.tbl_filter(function(artifact)
            return artifact.format == opts.format
        end, artifacts)
    end

    if opts.producer then
        artifacts = vim.tbl_filter(function(artifact)
            return artifact.producer == opts.producer
        end, artifacts)
    end

    if opts.paths then
        local allowed = path_set(opts.paths)
        artifacts = vim.tbl_filter(function(artifact)
            return artifact.path and allowed[path_key(artifact.path)] == true
        end, artifacts)
    end

    table.sort(artifacts, function(left, right)
        return (left.path or "") < (right.path or "")
    end)
    return artifacts
end

local function select_artifact(project, opts)
    if opts.path then
        return {
            path = util.resolve_path(opts.path, project.root),
            format = vim.fn.fnamemodify(opts.path, ":e"),
        }
    end

    local artifacts = M.artifacts(project, opts)
    if #artifacts == 0 then
        return nil
    end
    if #artifacts == 1 then
        return artifacts[1]
    end

    return nil,
        {
            ok = false,
            reason = "ambiguous_artifact",
            artifacts = artifacts,
            message = "Multiple Typst artifacts match; pass path or format",
        }
end

local function artifact_label(project, item)
    local producer = item.producer and ("[" .. item.producer .. "] ") or ""
    return ("%s %s%s"):format(
        item.format or vim.fn.fnamemodify(item.path or "", ":e"),
        producer,
        util.relpath(item.path or "", project.root)
    )
end

--- Open one exported artifact, prompting when multiple artifacts are available.
---@param project table Project state whose artifact records should be inspected.
---@param opts? table Selection/opening controls such as format and UI behavior.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table|nil result Open status and artifact metadata, or nil when selection is canceled.
function M.open(project, opts, notify)
    opts = opts or {}
    if
        not opts.path
        and (
            opts.prompt == true
            or opts.select == true
            or opts.interactive == true
        )
    then
        local artifacts = M.artifacts(project, opts)
        if #artifacts > 1 then
            vim.ui.select(artifacts, {
                prompt = "Open Typst artifact",
                format_item = function(item)
                    return artifact_label(project, item)
                end,
            }, function(item)
                if not item then
                    return
                end
                local next_opts = vim.tbl_extend("force", opts, {
                    path = item.path,
                    prompt = false,
                    select = false,
                    interactive = false,
                })
                M.open(project, next_opts, notify)
            end)
            return {
                ok = true,
                pending = true,
                reason = "selecting_artifact",
                artifacts = artifacts,
            }
        end
    end

    local artifact, selection_error = select_artifact(project, opts)
    if selection_error then
        return selection_error
    end
    if not artifact or not artifact.path then
        return {
            ok = false,
            reason = "missing_artifact",
            message = "No Typst artifact is registered",
        }
    end
    if
        vim.fn.filereadable(artifact.path) ~= 1
        and vim.fn.isdirectory(artifact.path) ~= 1
    then
        return {
            ok = false,
            reason = "missing_file",
            path = artifact.path,
            message = "Typst artifact does not exist",
        }
    end

    if vim.ui and type(vim.ui.open) == "function" and opts.edit ~= true then
        local object, err = open_helper.ui_open(artifact.path)
        if object then
            notify_user(
                notify,
                ("Opened %s"):format(util.relpath(artifact.path, project.root))
            )
            return {
                ok = true,
                artifact = artifact,
                opened = true,
                opener = object,
            }
        end
        log.add("warn", "vim.ui.open failed for artifact", {
            path = artifact.path,
            error = err,
        })
    end

    util.edit_existing_or_path(artifact.path)
    notify_user(
        notify,
        ("Opened %s"):format(util.relpath(artifact.path, project.root))
    )
    return {
        ok = true,
        artifact = artifact,
        opened = true,
    }
end

local function remove_file(path)
    local ok, result, err = pcall(vim.uv.fs_unlink, path)
    if ok and result == true then
        return true
    end
    if ok and result == nil and vim.fn.filereadable(path) == 0 then
        return true
    end
    return false, err or result
end

--- Remove artifacts still owned by typst.nvim.
---@param project table Project state whose artifact ownership records should be checked.
---@param opts? table Clean controls; `force=true` removes modified artifacts too.
---@param notify? fun(message:string, level?:integer) Notification sink used by commands/API calls.
---@return table result Deleted, skipped, and failed artifact paths.
function M.clean(project, opts, notify)
    opts = opts or {}
    local artifacts = M.artifacts(project, opts)
    local keep = path_set(opts.keep_paths or {})
    local deleted = {}
    local failed = {}
    local skipped = {}

    for _, artifact in ipairs(artifacts) do
        if artifact.path and vim.fn.filereadable(artifact.path) == 1 then
            if keep[path_key(artifact.path)] then
                skipped[#skipped + 1] = {
                    path = artifact.path,
                    reason = "active_preview",
                }
                goto continue
            end
            -- Cleaning is conservative: a file whose fingerprint changed since
            -- creation is treated as user-owned unless the caller forces it.
            local owned, reason = M.owned_current(project, artifact.path)
            if not owned and opts.force ~= true then
                skipped[#skipped + 1] = {
                    path = artifact.path,
                    reason = reason,
                }
            else
                local ok, err = remove_file(artifact.path)
                if ok then
                    deleted[#deleted + 1] = artifact.path
                    local state = artifact_state(project)
                    state.owned[path_key(artifact.path)] = nil
                    artifacts_service.set(project, { owned = state.owned })
                else
                    failed[#failed + 1] = {
                        path = artifact.path,
                        error = err,
                    }
                end
            end
        end
        ::continue::
    end

    if #failed > 0 or #skipped > 0 then
        notify_user(
            notify,
            #failed > 0 and "Failed to clean one or more Typst artifacts"
                or "Skipped unowned or modified Typst artifacts",
            vim.log.levels.ERROR
        )
    else
        notify_user(
            notify,
            ("Cleaned %d Typst artifact%s"):format(
                #deleted,
                #deleted == 1 and "" or "s"
            )
        )
    end

    local artifact_state = artifacts_service.get(project) or {}
    artifacts_service.set(project, {
        items = vim.tbl_filter(function(artifact)
            return not vim.tbl_contains(deleted, artifact.path)
        end, artifact_state.items or {}),
    })

    events.emit("TypstArtifactsCleaned", project, {
        deleted = deleted,
        failed = failed,
        skipped = skipped,
        producer = opts.producer,
    })

    return {
        ok = #failed == 0 and #skipped == 0,
        deleted = deleted,
        failed = failed,
        skipped = skipped,
        count = #deleted,
    }
end

return M
