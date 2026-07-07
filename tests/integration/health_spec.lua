local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local output_ownership = require("typst.resources.outputs")
local preview = require("typst.preview.controller")

local case_id = 0

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local function run_case(name, fn)
    case_id = case_id + 1
    cleanup()

    local ok, err = xpcall(fn, debug.traceback)

    cleanup()

    if not ok then
        error(("health integration case failed [%s]:\n%s"):format(name, err))
    end
end

local function capture_health()
    local messages = {}
    local old_health = vim.health

    vim.health = {
        start = function(message)
            messages[#messages + 1] = { level = "start", message = message }
        end,
        ok = function(message)
            messages[#messages + 1] = { level = "ok", message = message }
        end,
        warn = function(message)
            messages[#messages + 1] = { level = "warn", message = message }
        end,
        error = function(message)
            messages[#messages + 1] = { level = "error", message = message }
        end,
    }

    local ok, err = xpcall(function()
        require("typst.health").check()
    end, debug.traceback)

    vim.health = old_health

    if not ok then
        error(err)
    end

    return messages
end

local function has_message(messages, level, pattern)
    for _, item in ipairs(messages) do
        if
            (level == nil or item.level == level)
            and item.message:find(pattern, 1, true)
        then
            return true
        end
    end
    return false
end

local function with_preview_unavailable(fn)
    local old_available = preview.available
    local old_command_available = preview.command_available

    rawset(preview, "available", function()
        return false
    end)
    rawset(preview, "command_available", function()
        return false
    end)
    local ok, err = xpcall(fn, debug.traceback)

    preview.available = old_available
    preview.command_available = old_command_available

    if not ok then
        error(err)
    end
end

run_case("native preview and project report", function()
    typst.setup({
        root = root,
        preview = {
            fallback = "view",
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    typst.project.set_main(main)

    local messages
    with_preview_unavailable(function()
        messages = capture_health()
    end)
    local saw_native_preview = false
    local saw_project_decision = false
    local saw_project_diagnostics = false
    local saw_project_semantic = false
    local saw_project_index_cache = false
    local saw_metadata_symbols = false
    local saw_semantic_status = false
    local saw_conceal_math_status = false
    local saw_import_scan_entry_cap = false

    for _, item in ipairs(messages) do
        assert(
            not item.message:match("delegated later"),
            "health output should describe current preview behavior instead of future delegation"
        )

        if
            item.level == "ok" and item.message:match("Preview: native viewer")
        then
            saw_native_preview = true
        end

        if
            item.level == "ok"
            and item.message:find("tests/fixtures/basic/main.typ", 1, true)
            and item.message:find("root_source=", 1, true)
            and item.message:find("main_source=", 1, true)
        then
            saw_project_decision = true
        end

        if
            item.level == "ok"
            and item.message:find("tinymist_nvim_lsp=not_attached", 1, true)
            and item.message:find(
                "compiler_diagnostics=fallback_active",
                1,
                true
            )
        then
            saw_project_diagnostics = true
        end

        if
            item.level == "ok"
            and item.message:find("semantic_provider=tinymist", 1, true)
            and item.message:find(
                "semantic_provider_attached=not_attached",
                1,
                true
            )
        then
            saw_project_semantic = true
        end

        if
            item.level == "ok"
            and item.message:find("index_collect_cache=", 1, true)
            and item.message:find("index_file_cache=", 1, true)
            and item.message:find("index_bibliography_cache=", 1, true)
        then
            saw_project_index_cache = true
        end

        if
            item.level == "ok"
            and item.message:find("Typst metadata:", 1, true)
            and item.message:find("symbols", 1, true)
            and item.message:find("emojis", 1, true)
            and not item.message:find("docs", 1, true)
        then
            saw_metadata_symbols = true
        end

        if
            item.level == "ok"
            and item.message:find("Semantic provider: tinymist", 1, true)
        then
            saw_semantic_status = true
        end

        if
            item.message:find("Tree-sitter conceal math captures", 1, true)
            or item.message:find("too old for rich math conceal", 1, true)
        then
            saw_conceal_math_status = true
        end

        if
            item.level == "ok"
            and item.message:find("Import scan:", 1, true)
            and item.message:find("entries", 1, true)
        then
            saw_import_scan_entry_cap = true
        end
    end

    assert(
        saw_native_preview,
        "health output should explain native TypstPreview behavior"
    )
    assert(
        saw_project_decision,
        "health output should expose attached project root/main decisions"
    )
    assert(
        saw_project_diagnostics,
        "health output should expose effective project diagnostics policy"
    )
    assert(
        saw_project_semantic,
        "health output should expose effective project semantic provider state"
    )
    assert(
        saw_project_index_cache,
        "health output should expose project index cache statistics"
    )
    assert(
        saw_metadata_symbols,
        "health output should expose bundled symbol and emoji metadata"
    )
    assert(
        saw_semantic_status,
        "health output should expose global semantic provider status"
    )
    assert(
        saw_conceal_math_status,
        "health output should report rich math conceal parser compatibility"
    )
    assert(
        saw_import_scan_entry_cap,
        "health should report the import-scan entry cap"
    )
end)
run_case("missing treesitter is warning-only", function()
    typst.setup({
        root = root,
        compile = {
            provider = "noop",
        },
        preview = {
            fallback = "view",
        },
    })
    local old_get_lang = vim.treesitter.language.get_lang
    local old_query_get = vim.treesitter.query.get

    rawset(vim.treesitter.language, "get_lang", function()
        error("missing typst parser")
    end)
    rawset(vim.treesitter.query, "get", function()
        error("missing typst query")
    end)
    local messages
    local ok, err = xpcall(function()
        with_preview_unavailable(function()
            messages = capture_health()
        end)
    end, debug.traceback)

    vim.treesitter.language.get_lang = old_get_lang
    vim.treesitter.query.get = old_query_get

    if not ok then
        error(err)
    end

    local saw_parser_warning = false
    local query_warnings = 0
    local saw_typst_not_required = false

    for _, item in ipairs(messages) do
        assert(
            not (
                    item.level == "error"
                    and item.message:find("Tree-sitter", 1, true)
                ),
            "missing Tree-sitter should be reported as warnings, not errors"
        )

        if
            item.level == "warn"
            and item.message == "Tree-sitter Typst parser was not detected"
        then
            saw_parser_warning = true
        end

        if
            item.level == "warn"
            and item.message:find("Tree-sitter query failed to load:", 1, true)
        then
            query_warnings = query_warnings + 1
        end

        if
            item.level == "ok"
            and item.message
                == "Typst executable: not required by configured compiler provider"
        then
            saw_typst_not_required = true
        end
    end

    assert(
        saw_parser_warning,
        "health should warn when the Tree-sitter parser is unavailable"
    )
    assert(
        query_warnings == 6,
        ("health should warn for all bundled Tree-sitter queries, got %d"):format(
            query_warnings
        )
    )
    assert(
        saw_typst_not_required,
        "custom compiler provider health should not require the Typst CLI"
    )
end)
run_case("compiler provider state", function()
    local provider = {
        name = "health-provider",
        compile = function(project, callback)
            typst_test_compiler(project).last_command =
                { "health-provider", "compile", project.main }
            typst_test_compiler(project).last_cwd = project.root
            callback({ code = 0, stale = false })
            return { pid = 4241 }
        end,
        start = function(project, _callback, run_config)
            typst_test_compiler(project).last_command = {
                "health-provider",
                "watch",
                project.main,
                run_config.compile.profile,
            }
            typst_test_compiler(project).last_cwd = project.root
            return { pid = 4242 }
        end,
        stop = function(_project, callback)
            if callback then
                callback({ code = 0, stale = false, stopped = true })
            end
        end,
        status = function(project)
            return "health-" .. typst_test_compiler(project).status
        end,
        output = function(_project, run_config)
            return typst_test_cache_path("health-provider/")
                .. (run_config.compile.profile or "default")
                .. ".pdf"
        end,
    }

    typst.setup({
        root = root,
        compile = {
            provider = provider,
            profiles = {
                custom = {},
            },
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)
    typst.compiler.watch({ profile = "custom" })
    local failed_release_lease = assert(
        output_ownership.acquire(
            typst_test_cache_path("health-provider/release-failure.pdf"),
            output_ownership.owner("health-release-failure", project)
        )
    )
    vim.fn.writefile({
        vim.json.encode({
            pid = 999999999,
            path = failed_release_lease.path,
            owner = { kind = "foreign-owner" },
        }),
    }, output_ownership._owner_path(failed_release_lease.path))
    assert(
        output_ownership.release(failed_release_lease),
        "health fixture should release in-process lease despite lock cleanup failure"
    )

    local messages = capture_health()

    local saw_provider_state = false
    for _, item in ipairs(messages) do
        if
            item.level == "ok"
            and item.message:find("status=health-watching", 1, true)
            and item.message:find("profile=custom", 1, true)
            and item.message:find("cwd=" .. root, 1, true)
            and item.message:find("command=health-provider watch", 1, true)
            and item.message:find("watcher_pid=4242", 1, true)
            and item.message:find("active_leases=1", 1, true)
            and item.message:find("blockers=", 1, true)
            and item.message:find("compiler_watcher", 1, true)
            and item.message:find("output_lease", 1, true)
            and item.message:find(
                "last_output_lock_failure=foreign_lock_owner",
                1,
                true
            )
            and item.message:find("root_source=config.root", 1, true)
            and item.message:find(
                "main_source=buffer variable vim.b.typst_main",
                1,
                true
            )
        then
            saw_provider_state = true
        end
    end

    assert(
        saw_provider_state,
        "health output should expose provider-aware active project state"
    )
    assert(
        has_message(
            messages,
            "warn",
            "Last output lock release failure: foreign_lock_owner"
        ),
        "health output should expose global output lock release failures"
    )

    typst.compiler.stop()
    vim.fn.delete(failed_release_lease.lock_path, "rf")

    typst.setup({
        root = root,
        compile = {
            provider = "typst_missing_health_provider",
        },
    })
    messages = capture_health()

    local saw_missing_provider = false
    for _, item in ipairs(messages) do
        if
            item.level == "warn"
            and item.message:find(
                "Compiler provider module could not be loaded: typst_missing_health_provider",
                1,
                true
            )
        then
            saw_missing_provider = true
        end
    end

    assert(
        saw_missing_provider,
        "health should warn about missing string compiler providers"
    )

    package.preload["typst_health_missing_output_provider"] = function()
        return {
            name = "typst-health-missing-output-provider",
            compile = function() end,
            start = function() end,
            stop = function() end,
            status = function()
                return "idle"
            end,
        }
    end
    typst.setup({
        root = root,
        compile = {
            provider = "typst_health_missing_output_provider",
        },
    })
    messages = capture_health()
    package.preload["typst_health_missing_output_provider"] = nil
    package.loaded["typst_health_missing_output_provider"] = nil

    assert(
        has_message(
            messages,
            "warn",
            "Compiler provider typst_health_missing_output_provider is missing method output"
        ),
        "health should warn when non-outputless providers omit output()"
    )

    package.preload["typst_health_outputless_provider"] = function()
        return {
            name = "typst-health-outputless-provider",
            outputless = true,
            compile = function() end,
            start = function() end,
            stop = function() end,
            status = function()
                return "idle"
            end,
        }
    end
    typst.setup({
        root = root,
        compile = {
            provider = "typst_health_outputless_provider",
        },
    })
    messages = capture_health()
    package.preload["typst_health_outputless_provider"] = nil
    package.loaded["typst_health_outputless_provider"] = nil

    assert(
        not has_message(messages, "warn", "missing method output"),
        "health should not warn when providers explicitly set outputless=true"
    )

    typst.reset({ force = true })
    vim.cmd("silent! %bwipeout!")

    local function_provider_executed = false
    typst.setup({
        root = root,
        compile = {
            provider = function()
                function_provider_executed = true
                return {
                    name = "health-callback-provider",
                    compile = function() end,
                    start = function() end,
                    stop = function() end,
                    status = function()
                        return "idle"
                    end,
                    output = function()
                        return nil
                    end,
                }
            end,
        },
    })
    messages = capture_health()

    assert(
        function_provider_executed == false,
        "health should not execute function-valued compiler providers"
    )
    assert(
        has_message(
            messages,
            "ok",
            "Compiler provider callback is configured; method shape cannot be inspected safely"
        ),
        "health should explain that callback providers are not statically inspected"
    )
end)
run_case("tinymist ownership report", function()
    local old_get_clients = vim.lsp.get_clients
    local old_coc_initialized = vim.g.coc_service_initialized

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local bufnr = vim.api.nvim_get_current_buf()

    local function tinymist_client()
        return {
            id = 42,
            name = "tinymist",
            config = {
                root_dir = root,
            },
            supports_method = function(_, method)
                return method == "textDocument/codeAction"
                    or method == "textDocument/semanticTokens/full"
                    or method == "textDocument/documentLink"
                    or method == "textDocument/codeLens"
                    or method == "workspace/executeCommand"
            end,
        }
    end

    local ok, err = xpcall(function()
        vim.g.coc_service_initialized = nil
        typst.setup({
            root = root,
            output_dir = typst_test_cache_path("health-tinymist-output"),
            diagnostics = {
                source = "fallback",
            },
        })
        typst.project.set_main(main)

        rawset(vim.lsp, "get_clients", function(opts)
            if opts and opts.bufnr and opts.bufnr ~= bufnr then
                return {}
            end
            return { tinymist_client() }
        end)

        local messages = capture_health()
        assert(
            has_message(messages, "ok", "Tinymist Neovim LSP mode: auto"),
            "health output should report Tinymist mode"
        )
        assert(
            has_message(
                messages,
                "ok",
                "Tinymist Neovim LSP client is attached"
            ),
            "health output should report global Tinymist attachment"
        )
        assert(
            has_message(
                messages,
                "ok",
                "Tinymist attached client: tinymist id=42"
            ),
            "health output should identify attached Tinymist clients"
        )
        assert(
            has_message(messages, "ok", "Tinymist capabilities detected:")
                and has_message(messages, "ok", "codeAction")
                and has_message(messages, "ok", "semanticTokens"),
            "health output should summarize detected Tinymist capabilities"
        )
        assert(
            has_message(messages, "ok", "Semantic provider: tinymist"),
            "health output should report provider-neutral semantic status"
        )
        assert(
            has_message(messages, "ok", "tinymist_nvim_lsp=attached")
                and has_message(messages, "ok", "semantic_provider=tinymist")
                and has_message(
                    messages,
                    "ok",
                    "semantic_provider_attached=attached"
                )
                and has_message(
                    messages,
                    "ok",
                    "compiler_diagnostics=fallback_suppressed_by_tinymist"
                ),
            "health output should explain project diagnostics suppression by Tinymist"
        )

        typst.setup({
            root = root,
            output_dir = typst_test_cache_path("health-tinymist-output"),
            diagnostics = {
                source = "fallback",
            },
            integrations = {
                tinymist = {
                    client_names = { "tinymist_custom" },
                },
            },
        })
        typst.project.set_main(main)
        rawset(vim.lsp, "get_clients", function(opts)
            if opts and opts.bufnr and opts.bufnr ~= bufnr then
                return {}
            end
            local client = tinymist_client()
            client.name = "tinymist_custom"
            return { client }
        end)

        messages = capture_health()
        assert(
            has_message(
                messages,
                "ok",
                "Tinymist attached client: tinymist_custom id=42"
            ),
            "health output should use configured Tinymist client names"
        )

        rawset(vim.lsp, "get_clients", function(opts)
            if opts and opts.bufnr and opts.bufnr ~= bufnr then
                return {}
            end
            return { tinymist_client() }
        end)

        vim.g.coc_service_initialized = 1
        typst.reset()
        typst.setup({
            root = root,
            output_dir = typst_test_cache_path("health-tinymist-output"),
            integrations = {
                tinymist = {
                    lsp = "auto",
                },
            },
        })
        messages = capture_health()
        assert(
            has_message(messages, "ok", "coc.nvim detected for Tinymist policy"),
            "health output should report Coc detection"
        )
        assert(
            has_message(messages, "ok", "Tinymist Neovim LSP auto mode skipped"),
            "health output should report Coc skip reason"
        )
        assert(
            has_message(
                messages,
                "ok",
                "Tinymist native clients detected but ignored by auto+Coc policy"
            ),
            "health output should report ignored native Tinymist clients under Coc policy"
        )
    end, debug.traceback)

    vim.lsp.get_clients = old_get_clients
    vim.g.coc_service_initialized = old_coc_initialized

    if not ok then
        error(err)
    end
end)
run_case("remote browser preview host warns", function()
    typst.setup({
        root = root,
        preview = {
            native = "browser",
            browser = {
                host = "0.0.0.0",
                allow_remote = true,
            },
        },
    })
    local messages = capture_health()
    assert(
        has_message(messages, "warn", "non-loopback host"),
        "health should warn when browser preview binds beyond loopback"
    )
end)
run_case("v:lua global collision is reported", function()
    local original = _G.typst_nvim_foldexpr
    _G.typst_nvim_foldexpr = function()
        return "user-owned-foldexpr"
    end

    local ok, err = xpcall(function()
        typst.setup({
            root = root,
            completion = {
                package_cache_prewarm = false,
            },
        })
        local messages = capture_health()
        assert(
            has_message(messages, "warn", "Owned v:lua globals:")
                and has_message(
                    messages,
                    "warn",
                    "Skipped typst_nvim_foldexpr: collision"
                ),
            "health should report skipped typst.nvim v:lua globals"
        )
    end, debug.traceback)

    _G.typst_nvim_foldexpr = original
    if not ok then
        error(err)
    end
end)
vim.cmd("qa!")
