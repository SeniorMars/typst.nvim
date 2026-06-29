local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local diagnostics = require("typst.diagnostics")
local typst = require("typst")

local case_id = 0

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.fn.setqflist({}, "r")
    end)
    pcall(vim.cmd, "silent! %bwipeout!")
end

local function run_case(name, fn)
    case_id = case_id + 1
    cleanup()

    local ok, err = xpcall(fn, debug.traceback)

    cleanup()

    if not ok then
        error(
            ("diagnostics publishing case failed [%s]:\n%s"):format(name, err)
        )
    end
end

local function wait_for_compile(done_ref)
    assert(
        vim.wait(10000, function()
            return done_ref.done
        end, 20),
        "Typst compile did not finish"
    )
end

run_case("compiler diagnostics publish events quickfix and logs", function()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("test-output"),
        diagnostics = {
            enabled = true,
            use_quickfix = true,
        },
    })

    local broken = root .. "/tests/fixtures/basic/broken.typ"
    vim.cmd.edit(broken)
    local project = typst.project.set_main(broken)

    local published_event = nil
    local cleared_event = nil
    local group = vim.api.nvim_create_augroup(
        "TypstDiagnosticsPublishing" .. case_id,
        { clear = true }
    )
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstDiagnosticsPublished",
        callback = function(args)
            published_event = args.data
        end,
    })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "TypstDiagnosticsCleared",
        callback = function(args)
            cleared_event = args.data
        end,
    })

    local compile = {
        done = false,
        result_code = nil,
    }

    local handle = typst.compiler.compile({}, function(result)
        compile.result_code = result.code
        compile.done = true
    end)
    assert(
        typst_test_compiler(project).process == handle,
        "project should track the active failing compile process"
    )

    wait_for_compile(compile)

    assert(compile.result_code ~= 0, "expected compile failure")
    assert(
        typst_test_compiler(project).process == nil,
        "project should clear one-shot compile process after failure"
    )

    local published = vim.diagnostic.get(
        0,
        { namespace = diagnostics.namespace_for(project) }
    )
    assert(#published > 0, "expected compiler diagnostics")

    local parsed = diagnostics.parse(
        project,
        ("%s:1:9999: error: impossible column"):format(broken)
    )
    local parsed_diag = parsed[vim.fn.bufadd(broken)][1]
    local first_line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
    assert(
        parsed_diag.col == #first_line,
        "diagnostic parser should clamp out-of-range columns to line byte length"
    )

    local parsed_qf = diagnostics.quickfix_items(parsed)
    assert(
        parsed_qf[1] and parsed_qf[1].type == "E",
        "diagnostics quickfix_items should convert error severity to quickfix type"
    )

    local quickfix = vim.fn.getqflist()
    assert(#quickfix > 0, "expected compiler diagnostics in quickfix")
    assert(published_event, "TypstDiagnosticsPublished event should be emitted")
    assert(
        published_event.key == project.key,
        "diagnostics published event had wrong project key"
    )
    assert(
        published_event.diagnostics_count == #published,
        "diagnostics published event had wrong count"
    )
    assert(
        published_event.diagnostic_buffers == 1,
        "diagnostics published event had wrong buffer count"
    )

    diagnostics.clear(project)
    assert(cleared_event, "TypstDiagnosticsCleared event should be emitted")
    assert(
        cleared_event.key == project.key,
        "diagnostics cleared event had wrong project key"
    )
    assert(
        cleared_event.diagnostics_count == 0,
        "diagnostics cleared event should report zero diagnostics"
    )

    local failed_log = nil
    for _, entry in ipairs(typst.ui.log()) do
        if entry.message == "compile failed" then
            failed_log = entry
            break
        end
    end

    assert(failed_log, "expected compile failure to be logged")
    assert(
        failed_log.fields.stderr and failed_log.fields.stderr ~= "",
        "compile failure log should include stderr"
    )
    assert(
        failed_log.fields.stderr:match("broken%.typ")
            or failed_log.fields.stderr:match("error"),
        "compile failure stderr should include Typst output"
    )
end)

run_case("included-file diagnostics publish to owned buffers", function()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("diagnostics-multifile-output"),
        diagnostics = {
            enabled = true,
            use_quickfix = true,
        },
    })

    local main = root .. "/tests/fixtures/basic/includes-broken.typ"
    local broken = root .. "/tests/fixtures/basic/broken.typ"
    vim.cmd.edit(main)
    local project = typst.project.set_main(main)

    local compile = { done = false }
    typst.compiler.compile({}, function()
        compile.done = true
    end)
    wait_for_compile(compile)

    local broken_bufnr = vim.fn.bufnr(broken)
    assert(
        broken_bufnr > 0,
        "diagnostics should create or reuse a buffer for the included broken file"
    )

    local namespace = diagnostics.namespace_for(project)
    local broken_diagnostics =
        vim.diagnostic.get(broken_bufnr, { namespace = namespace })
    assert(
        #broken_diagnostics > 0,
        "expected diagnostics on the included broken file"
    )
    assert(
        broken_diagnostics[1].lnum == 2,
        "included-file diagnostic should keep the source line"
    )

    local main_diagnostics = vim.diagnostic.get(
        vim.api.nvim_get_current_buf(),
        { namespace = namespace }
    )
    assert(
        #main_diagnostics > 0,
        "expected import context diagnostic on the main buffer"
    )
    assert(
        main_diagnostics[1].severity == vim.diagnostic.severity.HINT,
        "Typst help diagnostics should publish as hints"
    )

    local quickfix = vim.fn.getqflist()
    assert(#quickfix >= 2, "expected included-file diagnostics in quickfix")
    assert(
        quickfix[1].bufnr == broken_bufnr,
        "quickfix diagnostic should point to the included broken file"
    )

    assert(
        typst_test_diagnostics(project).buffers[broken_bufnr],
        "project should track included-file diagnostic buffer ownership"
    )
end)

run_case("Tinymist and Coc suppress fallback diagnostics", function()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("diagnostics-policy-output"),
        diagnostics = {
            enabled = true,
            source = "fallback",
            use_quickfix = true,
        },
    })

    local broken = root .. "/tests/fixtures/basic/broken.typ"
    vim.cmd.edit(broken)
    local project = typst.project.set_main(broken)
    local bufnr = vim.api.nvim_get_current_buf()

    local original_get_clients = vim.lsp.get_clients
    local original_coc_initialized = vim.g.coc_service_initialized
    vim.g.coc_service_initialized = nil

    local ok, err = xpcall(function()
        vim.lsp.get_clients = function(opts)
            if opts and opts.bufnr and opts.bufnr ~= bufnr then
                return {}
            end

            return {
                {
                    id = 7,
                    name = "tinymist",
                    offset_encoding = "utf-16",
                },
            }
        end

        local diagnostics_config =
            require("typst.config").unsafe_get().diagnostics

        assert(
            not diagnostics.should_publish(project),
            "Tinymist should suppress fallback diagnostics"
        )
        diagnostics_config.source = "always"
        assert(
            diagnostics.should_publish(project),
            "always diagnostics should publish with Tinymist"
        )
        diagnostics_config.source = "off"
        assert(
            not diagnostics.should_publish(project),
            "off diagnostics should not publish"
        )
        diagnostics_config.source = "fallback"

        vim.lsp.get_clients = function()
            return {}
        end
        vim.g.coc_service_initialized = 1
        assert(
            not diagnostics.should_publish(project),
            "Coc should suppress fallback diagnostics when native Tinymist is hidden"
        )
        assert(
            diagnostics.policy_state(project)
                == "fallback_suppressed_by_tinymist",
            "Coc suppression should use the Tinymist suppression status"
        )
        diagnostics_config.source = "always"
        assert(
            diagnostics.should_publish(project),
            "always diagnostics should publish with Coc"
        )
        diagnostics_config.source = "fallback"

        local compile = {
            done = false,
            result_code = nil,
        }
        typst.compiler.compile({}, function(result)
            compile.result_code = result.code
            compile.done = true
        end)

        wait_for_compile(compile)

        assert(compile.result_code ~= 0, "expected compile failure")

        local namespace = diagnostics.namespace_for(project)
        assert(
            #vim.diagnostic.get(bufnr, { namespace = namespace }) == 0,
            "fallback diagnostics should not publish with Tinymist"
        )
        assert(
            #vim.fn.getqflist() == 0,
            "fallback diagnostics should not populate quickfix with Tinymist"
        )
    end, debug.traceback)

    vim.lsp.get_clients = original_get_clients
    vim.g.coc_service_initialized = original_coc_initialized

    if not ok then
        error(err)
    end
end)

vim.cmd("qa!")
