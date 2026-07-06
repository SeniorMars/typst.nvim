local M = {}

local compiler = require("typst.compiler")
local config = require("typst.config")
local diagnostics = require("typst.diagnostics")
local metadata = require("typst.metadata")
local native_preview_session = require("typst.preview.native.session")
local semantic_provider = require("typst.integrations.semantic_provider")
local tinymist = require("typst.integrations.tinymist")
local preview = require("typst.integrations.typst_preview")
local project = require("typst.project")
local project_root = require("typst.project.root")
local project_store = require("typst.project.store")
local artifacts_service = require("typst.project.services.artifacts")
local compiler_service = require("typst.project.services.compiler")
local index_service = require("typst.project.services.index")
local preview_service = require("typst.project.services.preview")
local resource_session = require("typst.resources.session")
local output_ownership = require("typst.resources.outputs")
local util = require("typst.core.util")
local viewer = require("typst.viewer")

local function health()
    return vim.health or require("health")
end

local function start(message)
    local h = health()
    return (h.start or h.report_start)(message)
end

local function ok(message)
    local h = health()
    return (h.ok or h.report_ok)(message)
end

local function warn(message)
    local h = health()
    return (h.warn or h.report_warn)(message)
end

local function loopback_host(host)
    return host == "127.0.0.1"
        or host == "localhost"
        or host == "::1"
        or host == "[::1]"
end

local function info(message)
    local h = health()
    local fn = h.info or h.report_info
    if fn then
        return fn(message)
    end
    return ok(message)
end

local function error_(message)
    local h = health()
    return (h.error or h.report_error)(message)
end

local function provider_status(state)
    local ok, value = pcall(compiler.status, state)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end

    return (compiler_service.get(state) or {}).status
end

local function tool_provider_label(provider)
    if type(provider) == "string" then
        return provider
    end

    if type(provider) == "function" then
        return "callback"
    end

    if type(provider) == "table" then
        return provider.name or "table"
    end

    return "<none>"
end

local function check_string_compiler_provider(provider)
    if
        type(provider) ~= "string"
        or provider == "typst"
        or provider == "generic"
        or provider == "task"
    then
        return
    end

    local ok_providers, providers =
        pcall(require, "typst.integrations.providers")
    if ok_providers and providers.get("compiler", provider) then
        return
    end

    local ok_require, loaded = pcall(require, provider)
    if not ok_require then
        warn(
            ("Compiler provider module could not be loaded: %s"):format(
                provider
            )
        )
        return
    end

    for _, name in ipairs({ "compile", "start", "stop", "status", "output" }) do
        if type(loaded[name]) ~= "function" then
            warn(
                ("Compiler provider module %s is missing method %s"):format(
                    provider,
                    name
                )
            )
            return
        end
    end
end

local function conceal_math_capture_status()
    local previous = vim.api.nvim_get_current_buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local results = {
        xpcall(function()
            vim.api.nvim_set_current_buf(bufnr)
            vim.bo[bufnr].filetype = "typst"
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "$ cal(A) + bb(R) + frak(g) + bold(x) + a <= b + a -> b + a != b + abs(x) + norm(x) + sqrt(x) $",
            })
            local ok_query, query =
                pcall(vim.treesitter.query.get, "typst", "conceal")
            if not ok_query or not query then
                return false, "conceal query did not load"
            end

            local ok_parser, parser =
                pcall(vim.treesitter.get_parser, bufnr, "typst")
            if not ok_parser or not parser then
                return false, "Typst parser did not attach"
            end

            local ok_parse, trees = pcall(parser.parse, parser)
            if not ok_parse or not trees or not trees[1] then
                return false, "Typst parser did not produce a tree"
            end

            local captures = {}
            for id in query:iter_captures(trees[1]:root(), bufnr, 0, -1) do
                captures[query.captures[id]] = true
            end

            if not captures["conceal.math_call"] then
                return false, "missing conceal.math_call capture"
            end
            if not captures["conceal.math_operator"] then
                return false, "missing conceal.math_operator capture"
            end

            return true
        end, debug.traceback),
    }

    if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    if vim.api.nvim_buf_is_valid(previous) then
        pcall(vim.api.nvim_set_current_buf, previous)
    end

    if not results[1] then
        return false, tostring(results[2])
    end
    if results[2] == true then
        return true
    end
    return false, tostring(results[3] or results[2])
end

local function active_pid(handle)
    if not handle then
        return nil
    end

    if handle.pid then
        return handle.pid
    end

    if handle.handle and handle.handle.pid then
        return handle.handle.pid
    end
end

local tinymist_capability_methods = {
    { label = "semanticTokens", method = "textDocument/semanticTokens/full" },
    { label = "codeAction", method = "textDocument/codeAction" },
    { label = "formatting", method = "textDocument/formatting" },
    { label = "documentHighlight", method = "textDocument/documentHighlight" },
    { label = "documentLink", method = "textDocument/documentLink" },
    { label = "documentSymbol", method = "textDocument/documentSymbol" },
    { label = "foldingRange", method = "textDocument/foldingRange" },
    { label = "definition", method = "textDocument/definition" },
    { label = "references", method = "textDocument/references" },
    { label = "hover", method = "textDocument/hover" },
    { label = "inlayHint", method = "textDocument/inlayHint" },
    { label = "documentColor", method = "textDocument/documentColor" },
    { label = "codeLens", method = "textDocument/codeLens" },
    { label = "rename", method = "textDocument/rename" },
    { label = "signatureHelp", method = "textDocument/signatureHelp" },
    { label = "workspaceSymbol", method = "workspace/symbol" },
    { label = "selectionRange", method = "textDocument/selectionRange" },
    { label = "executeCommand", method = "workspace/executeCommand" },
    { label = "onEnter", method = "experimental/onEnter" },
}

local function tinymist_raw_clients()
    if not (vim.lsp and type(vim.lsp.get_clients) == "function") then
        return {}
    end

    local ok, clients = pcall(require, "typst.integrations.tinymist.clients")
    if not ok then
        return {}
    end

    return vim.tbl_filter(function(client)
        return clients.matches_client_name(client)
    end, vim.lsp.get_clients())
end

local function tinymist_supports(client, method)
    if type(client.supports_method) ~= "function" then
        return nil
    end

    local ok, supported = pcall(client.supports_method, client, method)
    if ok then
        return supported == true
    end

    return nil
end

local function tinymist_client_label(client)
    local fields = {
        client.name or "tinymist",
    }
    if client.id then
        fields[#fields + 1] = ("id=%s"):format(client.id)
    end
    local client_config = client.config or {}
    if client_config.root_dir then
        fields[#fields + 1] = ("root=%s"):format(client_config.root_dir)
    end
    return table.concat(fields, " ")
end

local function tinymist_capability_summary(clients)
    local supported = {}
    local unknown_supports = false
    for _, capability in ipairs(tinymist_capability_methods) do
        for _, client in ipairs(clients) do
            local client_supported =
                tinymist_supports(client, capability.method)
            if client_supported == true then
                supported[#supported + 1] = capability.label
                break
            elseif client_supported == nil then
                unknown_supports = true
            end
        end
    end

    if #supported > 0 then
        table.sort(supported)
        return table.concat(supported, ", ")
    end

    if unknown_supports then
        return "unknown (client does not expose supports_method)"
    end

    return "<none reported>"
end

local function export_label(export)
    if type(export) ~= "table" then
        return nil
    end

    local fields = {}
    if export.target then
        fields[#fields + 1] = ("target:%s"):format(export.target)
    end
    if export.mode then
        fields[#fields + 1] = ("mode:%s"):format(export.mode)
    end
    if export.profile then
        fields[#fields + 1] = ("profile:%s"):format(export.profile)
    end
    if export.provider then
        fields[#fields + 1] = ("provider:%s"):format(export.provider)
    end
    if export.output_format then
        fields[#fields + 1] = ("format:%s"):format(export.output_format)
    end
    return #fields > 0 and table.concat(fields, ",") or nil
end

local function artifact_count_label(state)
    local artifact_state = artifacts_service.get(state) or {}
    local document = 0
    local preview_count = 0
    local other = 0
    for _, artifact in ipairs(artifact_state.items or {}) do
        if artifact.producer == "preview" then
            preview_count = preview_count + 1
        elseif
            artifact.producer == nil
            or artifact.producer == "compile"
            or artifact.producer == "export"
        then
            document = document + 1
        else
            other = other + 1
        end
    end
    if document == 0 and preview_count == 0 and other == 0 then
        return nil
    end
    return ("document:%d,preview:%d,other:%d"):format(
        document,
        preview_count,
        other
    )
end

local function preview_export_count_label(state)
    local artifact_state = artifacts_service.get(state) or {}
    local total = 0
    local targets = {}
    local modes = {}
    local formats = {}
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

    local function append_counts(prefix, counts, out)
        local keys = vim.tbl_keys(counts)
        table.sort(keys)
        for _, key in ipairs(keys) do
            out[#out + 1] = ("%s:%s:%d"):format(prefix, key, counts[key])
        end
    end

    local labels = { ("total:%d"):format(total) }
    append_counts("target", targets, labels)
    append_counts("mode", modes, labels)
    append_counts("format", formats, labels)
    return table.concat(labels, ",")
end

local function blocker_count_label(blockers)
    if type(blockers) ~= "table" or #blockers == 0 then
        return nil
    end

    local counts = {}
    for _, blocker in ipairs(blockers) do
        local kind = blocker.kind or "unknown"
        counts[kind] = (counts[kind] or 0) + 1
    end
    local keys = vim.tbl_keys(counts)
    table.sort(keys)
    local labels = {}
    for _, key in ipairs(keys) do
        labels[#labels + 1] = ("%s:%d"):format(key, counts[key])
    end
    return table.concat(labels, ",")
end

local function project_status_line(state)
    local resolution = state.last_resolution or {}
    local compiler_state = compiler_service.get(state) or {}
    local index_state = index_service.get(state) or {}
    local preview_state = preview_service.get(state) or {}
    local resource_state = resource_session.snapshot(state) or {}
    local integration_state = state.services and state.services.integrations
        or {}
    local tinymist_last_ensure = integration_state.tinymist
            and (integration_state.tinymist.reason or tostring(
                integration_state.tinymist.ok
            ))
        or nil
    if not tinymist_last_ensure then
        if not tinymist.lsp_enabled() then
            tinymist_last_ensure = "off"
        elseif tinymist.lsp_mode() == "detect" then
            tinymist_last_ensure = "detect"
        else
            tinymist_last_ensure = "not_checked"
        end
    end
    local native_preview = native_preview_session.project_state(state)
    local index_stats = index_state.stats or {}
    local fields = {
        ("main=%s"):format(state.main),
        ("root=%s"):format(state.root),
        ("output=%s"):format(compiler_state.output),
        ("status=%s"):format(provider_status(state)),
        ("tinymist_nvim_lsp=%s"):format(
            tinymist.lsp_enabled()
                    and (tinymist.available_for_project(state) and "attached" or "not_attached")
                or "off"
        ),
        ("tinymist_lsp_mode=%s"):format(tinymist.lsp_mode()),
        ("tinymist_last_ensure=%s"):format(tinymist_last_ensure),
        ("semantic_provider=%s"):format(semantic_provider.name()),
        ("semantic_provider_attached=%s"):format(
            semantic_provider.available_for_project(state) and "attached"
                or "not_attached"
        ),
        ("compiler_diagnostics=%s"):format(diagnostics.policy_state(state)),
        ("root_source=%s"):format(
            resolution.root_source or state.root_source or "unknown"
        ),
        ("main_source=%s"):format(
            resolution.main_source or state.main_source or "unknown"
        ),
        ("main_confidence=%s"):format(
            resolution.main_confidence or state.main_confidence or "unknown"
        ),
        ("resolution_pending=%s"):format(
            resolution.resolution_pending or state.resolution_pending or "none"
        ),
        ("index_collect_cache=%d/%d"):format(
            index_stats.collect_hits or 0,
            index_stats.collect_misses or 0
        ),
        ("index_file_cache=%d/%d"):format(
            index_stats.file_hits or 0,
            index_stats.file_misses or 0
        ),
        ("index_bibliography_cache=%d/%d"):format(
            index_stats.bibliography_hits or 0,
            index_stats.bibliography_misses or 0
        ),
    }

    if index_state.fs_watch_mode then
        fields[#fields + 1] = ("index_fs_watch=%s active=%d wanted=%d failed=%d"):format(
            index_state.fs_watch_mode,
            index_state.fs_watch_active_count or 0,
            index_state.fs_watch_wanted_count or 0,
            index_state.fs_watch_failed_count or 0
        )
        if index_state.fs_watch_partial then
            fields[#fields + 1] = "index_fs_watch_partial=yes"
        end
        if index_state.fs_watch_first_failed_path then
            fields[#fields + 1] = ("index_fs_watch_first_failed=%s"):format(
                index_state.fs_watch_first_failed_path
            )
        end
    end

    local lease_count = #output_ownership.snapshot(state)
    if lease_count > 0 then
        fields[#fields + 1] = ("active_leases=%d"):format(lease_count)
    end
    local lock_failure = output_ownership.last_release_failure(state)
    if lock_failure then
        fields[#fields + 1] = ("last_output_lock_failure=%s"):format(
            lock_failure.error or "unknown"
        )
        if lock_failure.lock_path then
            fields[#fields + 1] = ("last_output_lock_path=%s"):format(
                lock_failure.lock_path
            )
        end
    end

    local operations_state = state.services and state.services.operations or {}
    local retained_count = vim.tbl_count(operations_state.retained_by_id or {})
    if retained_count > 0 then
        fields[#fields + 1] = ("retained_orphans=%d"):format(retained_count)
    end

    if compiler_state.last_profile then
        fields[#fields + 1] = ("profile=%s"):format(compiler_state.last_profile)
    end

    local artifact_counts = artifact_count_label(state)
    if artifact_counts then
        fields[#fields + 1] = ("artifacts=%s"):format(artifact_counts)
    end

    local preview_export_counts = preview_export_count_label(state)
    if preview_export_counts then
        fields[#fields + 1] = ("preview_exports=%s"):format(
            preview_export_counts
        )
    end

    if compiler_state.last_cwd then
        fields[#fields + 1] = ("cwd=%s"):format(compiler_state.last_cwd)
    end

    local preview_backend = preview_state.active
            and preview_state.active_backend
        or preview_state.last_backend
    if preview_backend then
        fields[#fields + 1] = ("preview_backend=%s"):format(preview_backend)
    end

    if native_preview.active then
        fields[#fields + 1] = ("preview_transport=%s"):format(
            native_preview.mode
        )
        if native_preview.url then
            fields[#fields + 1] = ("preview_url=%s"):format(native_preview.url)
        end
        if native_preview.shell_path then
            fields[#fields + 1] = ("preview_shell=%s"):format(
                native_preview.shell_path
            )
        end
        if native_preview.output then
            fields[#fields + 1] = ("preview_output=%s"):format(
                native_preview.output
            )
        end
    elseif preview_state.active and preview_state.active_output then
        fields[#fields + 1] = ("preview_output=%s"):format(
            preview_state.active_output
        )
    end

    local preview_export =
        export_label(preview_state.active_export or preview_state.last_export)
    if preview_export then
        fields[#fields + 1] = ("preview_export=%s"):format(preview_export)
    end

    if compiler_state.last_command then
        fields[#fields + 1] = ("command=%s"):format(
            table.concat(compiler_state.last_command, " ")
        )
    end

    if compiler_state.process then
        fields[#fields + 1] = ("process_pid=%s"):format(
            active_pid(compiler_state.process) or "<unknown>"
        )
    end

    if compiler_state.watcher then
        ---@type table
        local watcher = compiler_state.watcher
        fields[#fields + 1] = ("watcher_pid=%s"):format(
            active_pid(watcher) or "<unknown>"
        )
        fields[#fields + 1] = ("watcher_compiling=%s"):format(
            watcher.currently_compiling and "yes" or "no"
        )
        fields[#fields + 1] = ("watcher_cycle=%s"):format(watcher.cycle or 0)
        fields[#fields + 1] = ("watcher_cycle_generation=%s"):format(
            watcher.cycle_generation or 0
        )
        fields[#fields + 1] = ("watcher_last_cycle=%s"):format(
            watcher.last_cycle_status or "<none>"
        )
        if (watcher.unrecognized_status_lines or 0) > 0 then
            fields[#fields + 1] = ("watcher_unknown_output=%d"):format(
                watcher.unrecognized_status_lines
            )
        end
    end

    if compiler_state.watcher and compiler_state.watcher.cwd then
        fields[#fields + 1] = ("watcher_cwd=%s"):format(
            compiler_state.watcher.cwd
        )
    end

    if compiler_state.watcher and compiler_state.watcher.command then
        fields[#fields + 1] = ("watcher_command=%s"):format(
            table.concat(compiler_state.watcher.command, " ")
        )
    end

    local blocker_counts = blocker_count_label(resource_state.blockers)
    if blocker_counts then
        fields[#fields + 1] = ("blockers=%s"):format(blocker_counts)
    end

    return table.concat(fields, " ")
end

function M.check()
    start("typst.nvim")
    local opts = config.unsafe_get()
    info(
        "Help: :help typst.nvim, :help typst-health, :help :TypstStatus, :help :TypstTelemetry"
    )

    if vim.fn.has("nvim-0.11") == 1 then
        ok(
            ("Neovim %s"):format(
                vim.version().major
                    .. "."
                    .. vim.version().minor
                    .. "."
                    .. vim.version().patch
            )
        )
    else
        error_("Neovim 0.11+ is required")
    end

    local provider_label = config.provider_label()
    ok(("Compiler provider: %s"):format(provider_label))
    check_string_compiler_provider(opts.compile and opts.compile.provider)

    if provider_label ~= "typst" then
        ok("Typst executable: not required by configured compiler provider")
    elseif vim.fn.executable(util.command_executable(opts.executable)) == 1 then
        local executable =
            vim.fn.exepath(util.command_executable(opts.executable))
        local display = util.command_display(opts.executable)
        ok(
            ("Typst executable: %s%s"):format(
                executable,
                display ~= util.command_executable(opts.executable)
                        and (" via " .. display)
                    or ""
            )
        )
    else
        error_(
            ("Typst executable not found in PATH: %s"):format(
                util.command_executable(opts.executable)
            )
        )
    end

    local parser_ok = pcall(vim.treesitter.language.get_lang, "typst")
    if parser_ok then
        ok("Tree-sitter language alias for typst is available")
    else
        warn("Tree-sitter Typst parser was not detected")
    end

    for _, query_name in ipairs({
        "highlights",
        "textobjects",
        "folds",
        "indents",
        "injections",
        "conceal",
    }) do
        local query_ok, query =
            pcall(vim.treesitter.query.get, "typst", query_name)
        if query_ok and query then
            ok(("Tree-sitter query loaded: %s"):format(query_name))
        else
            warn(("Tree-sitter query failed to load: %s"):format(query_name))
        end
    end

    local conceal_math_ok, conceal_math_reason = conceal_math_capture_status()
    if conceal_math_ok then
        ok("Tree-sitter conceal math captures: math_call and math_operator")
    else
        warn(
            ("Tree-sitter Typst parser may be too old for rich math conceal: %s"):format(
                conceal_math_reason or "unknown parser/query mismatch"
            )
        )
    end

    local tinymist_mode = tinymist.lsp_mode()
    local coc_active = tinymist.coc_active()
    local raw_tinymist_clients = tinymist_raw_clients()
    local tinymist_clients = tinymist.lsp_enabled()
            and not (tinymist_mode == "auto" and coc_active)
            and raw_tinymist_clients
        or {}
    ok(("Tinymist Neovim LSP mode: %s"):format(tinymist_mode))
    local tinymist_startability = tinymist.startability()
    ok(
        ("Tinymist command: %s"):format(
            util.command_display(
                tinymist_startability.command or { "tinymist" }
            )
        )
    )
    if tinymist_startability.ok then
        ok(
            ("Tinymist startability: ok%s"):format(
                tinymist_startability.path
                        and (" (" .. tinymist_startability.path .. ")")
                    or ""
            )
        )
    elseif tinymist_startability.reason == "off" then
        ok("Tinymist startability: off by configuration")
    elseif tinymist_startability.reason == "detect" then
        ok("Tinymist startability: detect-only mode")
    elseif tinymist_startability.reason == "coc" then
        ok("Tinymist startability: delegated to coc.nvim")
    elseif tinymist_startability.reason == "disabled" then
        ok("Tinymist startability: disabled by global autostart flag")
    else
        warn(
            ("Tinymist startability: %s%s"):format(
                tinymist_startability.reason or "unknown",
                tinymist_startability.executable
                        and (" (" .. tinymist_startability.executable .. ")")
                    or ""
            )
        )
    end
    if coc_active then
        ok("coc.nvim detected for Tinymist policy")
    end

    if not tinymist.lsp_enabled() then
        ok(
            "Tinymist Neovim LSP integration is off; external LSP clients such as coc.nvim remain delegated"
        )
        if #raw_tinymist_clients > 0 then
            warn(
                ("Tinymist native clients detected but ignored by lsp=off: %d"):format(
                    #raw_tinymist_clients
                )
            )
        end
    elseif #tinymist_clients > 0 then
        ok("Tinymist Neovim LSP client is attached")
        for _, client in ipairs(tinymist_clients) do
            ok(
                ("Tinymist attached client: %s"):format(
                    tinymist_client_label(client)
                )
            )
        end
        local capability_summary = tinymist_capability_summary(tinymist_clients)
        ok(("Tinymist capabilities detected: %s"):format(capability_summary))
        if
            vim.tbl_contains(
                vim.split(capability_summary, ", ", { plain = true }),
                "codeAction"
            )
        then
            ok("Tinymist code actions are available for structural commands")
        else
            warn(
                "Tinymist Neovim LSP client is attached but does not report code action support"
            )
        end
    elseif tinymist_mode == "detect" then
        ok("Tinymist Neovim LSP integration is passive detect-only mode")
    elseif tinymist_mode == "auto" and coc_active then
        ok(
            'Tinymist Neovim LSP auto mode skipped: coc.nvim appears active; use integrations.tinymist.lsp = "start" to force native Tinymist'
        )
        if #raw_tinymist_clients > 0 then
            ok(
                ("Tinymist native clients detected but ignored by auto+Coc policy: %d"):format(
                    #raw_tinymist_clients
                )
            )
        end
    else
        warn(
            "Tinymist Neovim LSP client is not attached; TOC and structural actions will use fallbacks where available"
        )
    end

    local semantic_status = semantic_provider.status()
    ok(
        ("Semantic provider: %s mode=%s backend=%s enabled=%s"):format(
            semantic_status.name,
            semantic_status.mode,
            semantic_status.backend,
            tostring(semantic_status.enabled)
        )
    )
    local registered_semantic = semantic_status.registered or {}
    if #registered_semantic > 0 then
        ok(
            ("Registered semantic providers: %s"):format(
                table.concat(registered_semantic, ", ")
            )
        )
    end

    start("typst.nvim configuration")
    ok(("Root markers: %s"):format(table.concat(opts.root_markers or {}, ", ")))
    ok(("Output directory: %s"):format(opts.output_dir or "<next to main>"))
    ok(("Output format: %s"):format(opts.output_format))
    local locks = output_ownership.locks()
    ok(("Output lock directory: %s"):format(output_ownership.lock_dir()))
    ok(
        ("Output locks: %d (use :TypstLocks / :TypstCleanLocks for recovery)"):format(
            #locks
        )
    )
    ok(
        ("Import scan: %s (%d files, %d ancestors, %d entries)"):format(
            opts.project.import_scan and "enabled" or "disabled",
            opts.project.import_scan_max_files,
            opts.project.import_scan_max_depth,
            opts.project.import_scan_max_entries
        )
    )
    local import_scan_stats = project_root._import_scan_stats()
    ok(
        ("Import scan stats: %s"):format(
            project_root.import_scan_stats_summary(import_scan_stats)
        )
    )
    ok(
        ("Dependency capture: %s"):format(
            opts.compile.deps and "enabled" or "disabled"
        )
    )
    local profiles = config.profile_names()
    ok(
        ("Compile profiles: %s"):format(
            #profiles > 0 and table.concat(profiles, ", ") or "<none>"
        )
    )
    ok(("Compiler diagnostics source: %s"):format(opts.diagnostics.source))
    ok(
        ("Diagnostics list: %s (%s)"):format(
            opts.diagnostics.use_quickfix and "enabled" or "manual",
            opts.diagnostics.list or "quickfix"
        )
    )
    ok(
        ("Diagnostics external paths: %s (max buffers per publish: %d)"):format(
            opts.diagnostics.external_paths or "bufadd",
            opts.diagnostics.max_buffers_per_publish or 0
        )
    )
    ok(
        ("Format provider: %s"):format(
            tool_provider_label(opts.format.provider)
        )
    )
    ok(("Lint provider: %s"):format(tool_provider_label(opts.lint.provider)))
    ok(
        ("Package syntax extensions: %s (%d specs)"):format(
            opts.syntax.package_extensions and "enabled" or "disabled",
            vim.tbl_count(opts.syntax.packages or {})
        )
    )
    ok(("Conceal: %s"):format(opts.conceal.enabled and "enabled" or "disabled"))
    ok(("Conceal renderer: %s"):format(opts.conceal.renderer.mode))
    local catalog = metadata.catalog()
    local artifacts = catalog.artifacts or {}
    local symbol_count = artifacts.symbols and artifacts.symbols.count or 0
    local emoji_count = artifacts.emojis and artifacts.emojis.count or 0
    ok(
        ("Typst metadata: %s (%d symbols, %d emojis)"):format(
            catalog.version,
            symbol_count,
            emoji_count
        )
    )
    ok(
        ("Tree-sitter folds: %s"):format(
            opts.folds.enabled and "enabled" or "disabled"
        )
    )
    ok(
        ("Typst indentation: %s"):format(
            opts.indent.enabled and "enabled" or "disabled"
        )
    )

    if type(opts.main) == "function" then
        ok("Main resolver: configured callback")
    elseif type(opts.main) == "string" then
        ok(("Main resolver: %s"):format(opts.main))
    elseif type(opts.main) == "table" then
        local roots = vim.tbl_keys(opts.main)
        table.sort(roots)
        ok(
            ("Main resolver: per-root mapping (%s)"):format(
                table.concat(roots, ", ")
            )
        )
    else
        ok(
            "Main resolver: buffer variable, directive, .typstmain, dependency graph, import scan, root heuristic, then current buffer"
        )
    end

    local effective_viewer = viewer.effective()
    ok(("Viewer provider: %s"):format(effective_viewer.provider or "generic"))
    if type(effective_viewer.open) == "function" then
        ok("Viewer: configured Lua callback")
    elseif
        type(effective_viewer.open) == "string"
        or type(effective_viewer.open) == "table"
    then
        local viewer_executable = util.command_executable(effective_viewer.open)
        if vim.fn.executable(viewer_executable) == 1 then
            local executable = vim.fn.exepath(viewer_executable)
            local display = util.command_display(effective_viewer.open)
            ok(
                ("Viewer executable: %s%s"):format(
                    executable,
                    display ~= viewer_executable and (" via " .. display) or ""
                )
            )
        else
            warn(
                ("Viewer executable is not in PATH: %s"):format(
                    viewer_executable
                )
            )
        end
    elseif vim.ui and vim.ui.open then
        ok("Viewer: vim.ui.open")
    else
        warn("Viewer: configure viewer.open because vim.ui.open is unavailable")
    end
    ok(
        ("Viewer args: %s"):format(
            #effective_viewer.args > 0
                    and table.concat(effective_viewer.args, " ")
                or "<none>"
        )
    )
    ok(
        ("Viewer forward: %s"):format(
            effective_viewer.forward ~= nil and "configured"
                or "unsupported without an explicit backend"
        )
    )

    if opts.preview.provider == "typst-preview.nvim" then
        if preview.available() or preview.command_available() then
            ok("typst-preview.nvim compatibility preview is available")
        elseif opts.preview.fallback == "view" then
            warn(
                "Preview: typst-preview.nvim command unavailable; :TypstPreview falls back to :TypstView"
            )
        else
            warn(
                "Preview: typst-preview.nvim command unavailable; configure preview.open or use the native provider"
            )
        end
    elseif type(opts.preview.open) == "function" then
        ok("Preview: configured Lua callback")
    elseif opts.preview.native == "browser" then
        ok("Preview: native browser")
    elseif opts.preview.native == "auto" then
        ok("Preview: native browser with viewer fallback")
    else
        ok("Preview: native viewer")
    end
    if
        opts.preview.browser
        and opts.preview.browser.server ~= false
        and not loopback_host(opts.preview.browser.host or "127.0.0.1")
    then
        if opts.preview.browser.allow_remote == true then
            warn(
                "Preview browser server is configured for a non-loopback host; only enable this on trusted networks"
            )
        else
            warn(
                "Preview browser server non-loopback hosts are refused unless preview.browser.allow_remote = true"
            )
        end
    end

    start("typst.nvim projects")
    local projects = project_store.all()
    if next(projects) == nil then
        warn("No Typst projects are attached yet")
    else
        for _, state in pairs(projects) do
            ok(project_status_line(state))
        end
    end
end

return M
