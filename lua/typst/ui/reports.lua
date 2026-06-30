local M = {}

local config = require("typst.config")
local conceal = require("typst.conceal")
local compiler = require("typst.compiler")
local diagnostics = require("typst.diagnostics")
local metadata = require("typst.metadata")
local artifacts_service = require("typst.project.services.artifacts")
local compiler_service = require("typst.project.services.compiler")
local diagnostics_service = require("typst.project.services.diagnostics")
local graph_service = require("typst.project.services.graph")
local preview_cache = require("typst.preview.cache")
local native_preview_session = require("typst.preview.native.session")
local preview_service = require("typst.project.services.preview")
local viewer_service = require("typst.project.services.viewer")
local status = require("typst.ui.status")
local semantic_provider = require("typst.integrations.semantic_provider")
local tinymist = require("typst.integrations.tinymist")
local cache_registry = require("typst.core.cache_registry")
local util = require("typst.core.util")

function M.echo_lines(lines)
    vim.api.nvim_echo(
        vim.tbl_map(function(line)
            return { line, "Normal" }
        end, lines),
        true,
        {}
    )
end

function M.open_scratch_buffer(name, filetype, lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = filetype
    local named = pcall(vim.api.nvim_buf_set_name, buf, name)
    if not named then
        vim.api.nvim_buf_set_name(buf, ("%s %d"):format(name, buf))
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)

    return buf
end

local function compiler_status(state)
    local ok, value = pcall(compiler.status, state)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    return (compiler_service.get(state) or {}).status
end

local function tinymist_lsp_status(state)
    local mode = tinymist.lsp_mode()
    if mode == "off" then
        return "off"
    end

    if tinymist.available_for_project(state) then
        return ("%s attached"):format(mode)
    end

    if mode == "auto" and tinymist.coc_active() then
        return "auto skipped: coc.nvim"
    end

    return ("%s not attached"):format(mode)
end

local function semantic_status_label(state)
    local semantic_status = semantic_provider.status(state)
    local attached = semantic_status.attached and "attached" or "not attached"
    local enabled = semantic_status.enabled and "enabled" or "off"
    return ("%s %s backend=%s %s"):format(
        semantic_status.name,
        semantic_status.mode,
        semantic_status.backend,
        semantic_status.enabled and attached or enabled
    )
end

local function preview_export_label(export)
    if type(export) ~= "table" then
        return nil
    end

    local fields = {}
    if export.target then
        fields[#fields + 1] = ("target=%s"):format(export.target)
    end
    if export.mode then
        fields[#fields + 1] = ("mode=%s"):format(export.mode)
    end
    if export.profile then
        fields[#fields + 1] = ("profile=%s"):format(export.profile)
    end
    if export.provider then
        fields[#fields + 1] = ("provider=%s"):format(export.provider)
    end
    if export.output_format then
        fields[#fields + 1] = ("format=%s"):format(export.output_format)
    end
    return #fields > 0 and table.concat(fields, " ") or nil
end

local function count_label(counts)
    local labels = {}
    for key, count in pairs(counts or {}) do
        labels[#labels + 1] = ("%s=%d"):format(key, count)
    end
    table.sort(labels)
    return table.concat(labels, " ")
end

local function bytes_label(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then
        return ("%.1f MiB"):format(bytes / 1024 / 1024)
    end
    if bytes >= 1024 then
        return ("%.1f KiB"):format(bytes / 1024)
    end
    return ("%d B"):format(bytes)
end

local function artifact_producer_counts(state)
    local artifact_state = artifacts_service.get(state) or {}
    local counts = {
        document = 0,
        preview = 0,
        other = 0,
    }
    for _, artifact in ipairs(artifact_state.items or {}) do
        if artifact.producer == "preview" then
            counts.preview = counts.preview + 1
        elseif
            artifact.producer == nil
            or artifact.producer == "compile"
            or artifact.producer == "export"
        then
            counts.document = counts.document + 1
        else
            counts.other = counts.other + 1
        end
    end
    return counts
end

local function preview_export_counts(state)
    local artifact_state = artifacts_service.get(state) or {}
    local targets = {}
    local modes = {}
    local formats = {}
    local total = 0
    for _, artifact in ipairs(artifact_state.items or {}) do
        local preview_export = artifact.preview_export
        if
            artifact.producer == "preview"
            and type(preview_export) == "table"
        then
            total = total + 1
            if preview_export.target then
                targets[preview_export.target] = (
                    targets[preview_export.target] or 0
                ) + 1
            end
            if preview_export.mode then
                modes[preview_export.mode] = (modes[preview_export.mode] or 0)
                    + 1
            end
            local format = preview_export.output_format or artifact.format
            if format then
                formats[format] = (formats[format] or 0) + 1
            end
        end
    end
    if total == 0 then
        return nil
    end
    return {
        total = total,
        targets = targets,
        modes = modes,
        formats = formats,
    }
end

local function preview_cache_detail_lines(state)
    local status = preview_cache.status(state)
    if #status.entries == 0 then
        return {}
    end

    local lines = { "  preview cache entries:" }
    for _, entry in ipairs(status.entries) do
        local export = entry.preview_export or {}
        local detail = {}
        if entry.active then
            detail[#detail + 1] = "active"
        end
        if export.target then
            detail[#detail + 1] = ("target=%s"):format(export.target)
        end
        if export.mode then
            detail[#detail + 1] = ("mode=%s"):format(export.mode)
        end
        if export.profile then
            detail[#detail + 1] = ("profile=%s"):format(export.profile)
        end
        if export.output_format then
            detail[#detail + 1] = ("format=%s"):format(export.output_format)
        end
        lines[#lines + 1] = ("    %s  %s  %s"):format(
            bytes_label(entry.bytes),
            table.concat(detail, " "),
            util.relpath(entry.path or "", state.root)
        )
    end
    return lines
end

local function copy_preview_url(url)
    if type(url) ~= "string" or url == "" then
        return false
    end
    vim.g.typst_nvim_last_preview_url = url
    return pcall(vim.fn.setreg, "+", url)
end

function M.preview_status_lines(state)
    local preview_state = preview_service.get(state) or {}
    local native_preview = native_preview_session.project_state(state)
    local cache_status = preview_cache.status(state)
    local browser_config = (config.unsafe_get().preview or {}).browser or {}
    local lines = {
        "typst.nvim preview",
        ("  active: %s"):format(preview_state.active and "yes" or "no"),
    }
    local backend = preview_state.active and preview_state.active_backend
        or preview_state.last_backend
    if backend then
        lines[#lines + 1] = ("  backend: %s"):format(backend)
    end
    if native_preview.active then
        lines[#lines + 1] = ("  transport: %s"):format(native_preview.mode)
        if native_preview.url then
            lines[#lines + 1] = ("  url: %s"):format(native_preview.url)
        end
        if native_preview.shell_path then
            lines[#lines + 1] = ("  shell: %s"):format(
                native_preview.shell_path
            )
        end
        if native_preview.output then
            lines[#lines + 1] = ("  output: %s"):format(native_preview.output)
        end
    elseif preview_state.active_output then
        lines[#lines + 1] = ("  output: %s"):format(preview_state.active_output)
    end
    local last_url = preview_state.last_failed_url or preview_state.last_url
    if not native_preview.active and last_url then
        lines[#lines + 1] = ("  last url: %s"):format(last_url)
        if preview_state.last_failed_url and copy_preview_url(last_url) then
            lines[#lines + 1] = "  copy url: copied to + register"
        else
            lines[#lines + 1] =
                "  copy url: :let @+ = g:typst_nvim_last_preview_url"
        end
    end
    if preview_state.last_transport then
        lines[#lines + 1] = ("  last transport: %s"):format(
            preview_state.last_transport
        )
    end
    if preview_state.last_shell then
        lines[#lines + 1] = ("  last shell: %s"):format(
            preview_state.last_shell
        )
    end
    local export_label = preview_export_label(
        preview_state.active_export or preview_state.last_export
    )
    if export_label then
        lines[#lines + 1] = ("  export: %s"):format(export_label)
    end
    if type(preview_state.last_error) == "table" then
        local err = preview_state.last_error
        lines[#lines + 1] = ("  last error: %s"):format(
            err.message or err.reason or vim.inspect(err)
        )
        if err.url and err.url ~= last_url then
            lines[#lines + 1] = ("  error url: %s"):format(err.url)
        end
        if
            type(err.opener_candidates) == "table"
            and #err.opener_candidates > 0
        then
            lines[#lines + 1] = ("  opener candidates: %s"):format(
                table.concat(err.opener_candidates, " | ")
            )
        end
    end
    if preview_state.last_browser_refresh_skipped_ms then
        lines[#lines + 1] = ("  reload throttle: skipped, %sms remaining"):format(
            preview_state.last_browser_refresh_skipped_ms
        )
    end
    if
        browser_config.performance
        and browser_config.performance ~= "default"
    then
        lines[#lines + 1] = ("  browser performance: %s"):format(
            browser_config.performance
        )
    end
    if browser_config.app then
        lines[#lines + 1] = ("  browser app: %s"):format(browser_config.app)
    end
    if
        browser_config.reload_throttle_ms
        and browser_config.reload_throttle_ms > 0
    then
        lines[#lines + 1] = ("  browser reload throttle: %sms"):format(
            browser_config.reload_throttle_ms
        )
    end
    lines[#lines + 1] = ("  cache: %d entries, %s"):format(
        cache_status.count,
        bytes_label(cache_status.bytes)
    )
    lines[#lines + 1] = ("  cache limits: enabled=%s max_entries=%s max_bytes=%s ttl_ms=%s"):format(
        tostring(cache_status.limits.enabled ~= false),
        tostring(cache_status.limits.max_entries or 0),
        tostring(cache_status.limits.max_bytes or 0),
        tostring(cache_status.limits.ttl_ms or 0)
    )
    vim.list_extend(lines, preview_cache_detail_lines(state))
    return lines
end

function M.project_lines(state, bufnr, opts)
    opts = opts or {}
    local compiler_state = compiler_service.get(state) or {}
    local preview_state = preview_service.get(state) or {}
    local diagnostic_state = diagnostics_service.get(state) or {}
    local viewer_state = viewer_service.get(state) or {}
    local graph = graph_service.get(state) or {}
    local artifact_counts = artifact_producer_counts(state)
    local preview_exports = preview_export_counts(state)
    local buffers = vim.tbl_keys(state.bufs or {})
    table.sort(buffers)
    local diagnostic_buffers = vim.tbl_keys(diagnostic_state.buffers or {})
    table.sort(diagnostic_buffers)
    local resolution = (
        bufnr
        and state.resolutions
        and state.resolutions[bufnr]
    ) or state.last_resolution
    local catalog = metadata.catalog({ detect_version = true })
    local metadata_label = catalog.version
    if catalog.requested_version and catalog.version_mismatch then
        metadata_label = ("%s (Typst %s installed)"):format(
            catalog.version,
            catalog.requested_version
        )
    elseif not catalog.requested_version then
        metadata_label = ("%s (Typst version unknown)"):format(catalog.version)
    end

    local lines = {
        "typst.nvim",
        ("  root:   %s"):format(state.root),
        ("  main:   %s"):format(state.main),
        ("  output: %s"):format(compiler_state.output),
        ("  status: %s"):format(compiler_status(state)),
        ("  provider: %s"):format(config.provider_label()),
        ("  metadata: %s"):format(metadata_label),
        ("  conceal: %s"):format(
            bufnr and conceal.is_enabled(bufnr) and "enabled" or "disabled"
        ),
        ("  conceal renderer: %s"):format(config.get().conceal.renderer.mode),
        ("  semantic provider: %s"):format(semantic_status_label(state)),
        ("  tinymist nvim-lsp: %s"):format(tinymist_lsp_status(state)),
        ("  compiler diagnostics: %s"):format(diagnostics.policy_label(state)),
        ("  cwd:    %s"):format(compiler_state.last_cwd or state.root),
        ("  buffers: %d"):format(#buffers),
        ("  diagnostic buffers: %d"):format(#diagnostic_buffers),
    }

    if compiler_state.last_profile then
        lines[#lines + 1] = ("  profile: %s"):format(
            compiler_state.last_profile
        )
    end

    if
        artifact_counts.document > 0
        or artifact_counts.preview > 0
        or artifact_counts.other > 0
    then
        lines[#lines + 1] = ("  artifacts: document=%d preview=%d other=%d"):format(
            artifact_counts.document,
            artifact_counts.preview,
            artifact_counts.other
        )
    end
    if preview_exports then
        lines[#lines + 1] = ("  preview exports: total=%d target:%s mode:%s format:%s"):format(
            preview_exports.total,
            count_label(preview_exports.targets),
            count_label(preview_exports.modes),
            count_label(preview_exports.formats)
        )
    end
    if opts.detailed == true then
        vim.list_extend(lines, preview_cache_detail_lines(state))
        local cache_status = cache_registry.status()
        local cache_stats = cache_registry.stats()
        lines[#lines + 1] = ("  cache registry: loaded=%d unloaded=%d reset=%d clear=%d reload=%d"):format(
            cache_stats.loaded,
            cache_stats.unloaded,
            cache_stats.reset,
            cache_stats.clear,
            cache_stats.reload
        )
        if #cache_status.loaded > 0 then
            lines[#lines + 1] = ("    loaded: %s"):format(
                table.concat(cache_status.loaded, ", ")
            )
        end
    end

    if resolution then
        lines[#lines + 1] = ("  buffer: %s"):format(
            util.relpath(resolution.buffer, state.root)
        )
        lines[#lines + 1] = ("  root source: %s"):format(resolution.root_source)
        lines[#lines + 1] = ("  main source: %s"):format(resolution.main_source)
    end

    if compiler_state.last_command then
        lines[#lines + 1] = ("  command: %s"):format(
            table.concat(compiler_state.last_command, " ")
        )
    end

    if compiler_state.process then
        lines[#lines + 1] = ("  process pid: %s"):format(
            compiler_state.process.pid or "<unknown>"
        )
    end

    if viewer_state.provider then
        lines[#lines + 1] = ("  viewer provider: %s"):format(
            viewer_state.provider
        )
    end

    if viewer_state.backend then
        lines[#lines + 1] = ("  viewer backend: %s"):format(
            viewer_state.backend
        )
    end

    if compiler_state.watcher then
        local watcher = compiler_state.watcher
        lines[#lines + 1] = ("  watcher pid: %s"):format(
            watcher.handle and watcher.handle.pid or "<unknown>"
        )
        if watcher.command then
            lines[#lines + 1] = ("  watcher command: %s"):format(
                table.concat(watcher.command, " ")
            )
        end
        if watcher.cwd then
            lines[#lines + 1] = ("  watcher cwd: %s"):format(watcher.cwd)
        end
        lines[#lines + 1] = ("  watcher compiling: %s"):format(
            watcher.currently_compiling and "yes" or "no"
        )
        lines[#lines + 1] = ("  watcher cycle: %s"):format(watcher.cycle or 0)
        lines[#lines + 1] = ("  watcher cycle generation: %s"):format(
            watcher.cycle_generation or 0
        )
        lines[#lines + 1] = ("  watcher last cycle: %s"):format(
            watcher.last_cycle_status or "<none>"
        )
        if (watcher.unrecognized_status_lines or 0) > 0 then
            lines[#lines + 1] = ("  watcher unknown output: %d"):format(
                watcher.unrecognized_status_lines
            )
            lines[#lines + 1] = ("  watcher last unknown line: %s"):format(
                watcher.last_unrecognized_status_line or "<none>"
            )
        end
    end

    if viewer_state.command then
        lines[#lines + 1] = ("  viewer command: %s"):format(
            table.concat(viewer_state.command, " ")
        )
    end

    if viewer_state.cwd then
        lines[#lines + 1] = ("  viewer cwd: %s"):format(viewer_state.cwd)
    end

    local preview_backend = preview_state.active
            and preview_state.active_backend
        or preview_state.last_backend
    local preview_mode = preview_state.active and preview_state.active_mode
        or preview_state.last_mode
    local preview_command = preview_state.active
            and preview_state.active_command
        or preview_state.last_command
    local preview_cwd = preview_state.active and preview_state.active_cwd
        or preview_state.last_cwd

    if preview_backend then
        lines[#lines + 1] = ("  preview backend: %s"):format(preview_backend)
    end

    if preview_mode then
        lines[#lines + 1] = ("  preview mode: %s"):format(preview_mode)
    end

    if preview_command then
        lines[#lines + 1] = ("  preview command: %s"):format(
            table.concat(preview_command, " ")
        )
    end

    if preview_cwd then
        lines[#lines + 1] = ("  preview cwd: %s"):format(preview_cwd)
    end

    local native_preview = native_preview_session.project_state(state)
    if native_preview.active then
        lines[#lines + 1] = ("  preview transport: %s"):format(
            native_preview.mode
        )
        if native_preview.url then
            lines[#lines + 1] = ("  preview url: %s"):format(native_preview.url)
        end
        if native_preview.shell_path then
            lines[#lines + 1] = ("  preview shell: %s"):format(
                native_preview.shell_path
            )
        end
        if native_preview.output then
            lines[#lines + 1] = ("  preview output: %s"):format(
                native_preview.output
            )
        end
    elseif preview_state.active and preview_state.active_output then
        lines[#lines + 1] = ("  preview output: %s"):format(
            preview_state.active_output
        )
    end

    local export_label = preview_export_label(
        preview_state.active_export or preview_state.last_export
    )
    if export_label then
        lines[#lines + 1] = ("  preview export: %s"):format(export_label)
    end

    if compiler_state.last_result then
        lines[#lines + 1] = ("  last exit: %s"):format(
            vim.inspect(compiler_state.last_result.code)
        )
    end

    local dependencies = vim.tbl_keys(graph.dependencies or {})
    table.sort(dependencies)
    if #dependencies > 0 then
        lines[#lines + 1] = "  dependencies:"
        for _, dependency in ipairs(dependencies) do
            lines[#lines + 1] = ("    %s"):format(
                util.relpath(dependency, state.root)
            )
        end
    end

    return lines
end

function M.status_report_lines(snapshot)
    if not snapshot.attached then
        local lines = { "Typst:detached" }
        if snapshot.telemetry_report and #snapshot.telemetry_report > 0 then
            lines[#lines + 1] = "  telemetry:"
            for _, line in ipairs(snapshot.telemetry_report) do
                lines[#lines + 1] = "    " .. line
            end
        end
        return lines
    end

    local lines = {
        status.format(snapshot),
        ("  main: %s"):format(snapshot.main),
        ("  output: %s"):format(snapshot.output),
        ("  diagnostics: %d"):format(snapshot.diagnostics or 0),
        ("  watching: %s"):format(snapshot.watching and "yes" or "no"),
    }
    if (snapshot.watcher_unrecognized_status_lines or 0) > 0 then
        lines[#lines + 1] = ("  watcher unknown output: %d"):format(
            snapshot.watcher_unrecognized_status_lines
        )
        lines[#lines + 1] = ("  watcher last unknown line: %s"):format(
            snapshot.watcher_last_unrecognized_status_line or "<none>"
        )
    end
    local stats = snapshot.index_stats
    if type(stats) == "table" then
        lines[#lines + 1] = ("  index cache: collect %d/%d, files %d/%d, bibliography %d/%d"):format(
            stats.collect_hits or 0,
            stats.collect_misses or 0,
            stats.file_hits or 0,
            stats.file_misses or 0,
            stats.bibliography_hits or 0,
            stats.bibliography_misses or 0
        )
    end
    local fs_watchers = snapshot.index_fs_watchers
    if type(fs_watchers) == "table" and fs_watchers.mode then
        local suffix = ""
        if fs_watchers.reason then
            suffix = (" (%s)"):format(fs_watchers.reason)
        end
        lines[#lines + 1] = ("  index fs watchers: %s %d/%d cap=%s%s"):format(
            fs_watchers.mode,
            fs_watchers.active or 0,
            fs_watchers.wanted or 0,
            tostring(fs_watchers.cap or "auto"),
            suffix
        )
    end
    if snapshot.telemetry_report and #snapshot.telemetry_report > 0 then
        lines[#lines + 1] = "  telemetry:"
        for _, line in ipairs(snapshot.telemetry_report) do
            lines[#lines + 1] = "    " .. line
        end
    end
    return lines
end

local function status_label(snapshot)
    if snapshot.process_pid then
        return ("compiling pid %s"):format(snapshot.process_pid)
    end
    if snapshot.watcher_compiling then
        return "watching compiling"
    end
    if snapshot.watching then
        return "watching"
    end
    return snapshot.status or "idle"
end

local function result_label(snapshot)
    local status_value = snapshot.status or "idle"
    if status_value:find("success", 1, true) then
        return "last build success"
    end
    if
        status_value:find("error", 1, true)
        or status_value:find("failed", 1, true)
    then
        return "last build failed"
    end
    if snapshot.process_pid then
        return "active build"
    end
    return "last build unknown"
end

function M.status_all_lines(snapshots)
    if #snapshots == 0 then
        return { "No Typst projects are registered" }
    end

    local main_width = #"main"
    local state_width = #"state"
    for _, snapshot in ipairs(snapshots) do
        main_width =
            math.max(main_width, #(snapshot.main_name or snapshot.main or ""))
        state_width = math.max(state_width, #status_label(snapshot))
    end

    local lines = {
        ("%-" .. main_width .. "s  %-" .. state_width .. "s  %-18s  %s"):format(
            "main",
            "state",
            "result",
            "diagnostics"
        ),
    }

    for _, snapshot in ipairs(snapshots) do
        local diagnostics_count = snapshot.diagnostics or 0
        lines[#lines + 1] = (
            "%-"
            .. main_width
            .. "s  %-"
            .. state_width
            .. "s  %-18s  %d %s"
        ):format(
            snapshot.main_name or snapshot.main or "<unknown>",
            status_label(snapshot),
            result_label(snapshot),
            diagnostics_count,
            diagnostics_count == 1 and "error" or "errors"
        )
    end

    return lines
end

local function append_text_block(lines, title, text)
    if type(text) ~= "string" or text == "" then
        return false
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = title .. ":"
    for _, line in ipairs(util.split_lines(text)) do
        lines[#lines + 1] = line
    end

    return true
end

function M.compiler_output_lines(state)
    local compiler_state = compiler_service.get(state) or {}
    local lines = {
        "typst.nvim compiler output",
        ("  main: %s"):format(state.main),
        ("  output: %s"):format(compiler_state.output),
        ("  status: %s"):format(compiler_status(state)),
    }

    if compiler_state.last_command then
        lines[#lines + 1] = ("  command: %s"):format(
            table.concat(compiler_state.last_command, " ")
        )
    end

    if compiler_state.last_cwd then
        lines[#lines + 1] = ("  cwd: %s"):format(compiler_state.last_cwd)
    end

    if compiler_state.last_result then
        lines[#lines + 1] = ("  exit: %s"):format(
            vim.inspect(compiler_state.last_result.code)
        )
    end

    local has_output = false
    if compiler_state.last_result then
        has_output = append_text_block(
            lines,
            "stdout",
            compiler_state.last_result.stdout
        ) or has_output
        has_output = append_text_block(
            lines,
            "stderr",
            compiler_state.last_result.stderr
        ) or has_output
    end

    if compiler_state.watcher then
        has_output = append_text_block(
            lines,
            "watch stdout",
            compiler_state.watcher.stdout
        ) or has_output
        has_output = append_text_block(
            lines,
            "watch stderr",
            compiler_state.watcher.stderr
        ) or has_output
    end

    if not has_output then
        lines[#lines + 1] = ""
        lines[#lines + 1] =
            "No compiler stdout or stderr has been captured for this project."
    end

    return lines
end

return M
