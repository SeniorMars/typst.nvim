local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local process = require("typst.core.process")
local path_leases = require("typst.core.path_leases")
local typst = require("typst")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("export-spec-output"),
})

local original_spawn = process.spawn
local spawned = {}
local option_output_path = root .. "/--version"

local function stat_signature(stat)
    if not stat then
        return nil
    end
    local mtime = stat.mtime or {}
    return table.concat({
        stat.type or "",
        tostring(stat.size or ""),
        tostring(mtime.sec or ""),
        tostring(mtime.nsec or ""),
    }, "\0")
end

local option_output_before = stat_signature(vim.uv.fs_stat(option_output_path))

local function mock_output_path(command)
    local output = command[#command]
    assert(
        type(output) == "string" and not output:match("^%-"),
        ("mock process output target must be a path, got %s in %s"):format(
            vim.inspect(output),
            vim.inspect(command)
        )
    )
    return output
end

process.spawn = function(command, opts, handlers)
    local handle = {
        command = command,
        opts = opts,
        handlers = handlers,
        closed = false,
    }

    function handle:is_closing()
        return self.closed
    end

    function handle:kill()
        self.closed = true
    end

    function handle:finish(result, write_output)
        self.closed = true
        if write_output then
            local output_text = type(write_output) == "table"
                    and write_output.text
                or write_output
            local output = mock_output_path(self.command)
            vim.fn.mkdir(vim.fn.fnamemodify(output, ":h"), "p")
            vim.fn.writefile({ tostring(output_text) }, output)
            if type(write_output) == "table" and write_output.mtime then
                vim.uv.fs_utime(output, write_output.mtime, write_output.mtime)
            end
        end
        handlers.on_exit(result)
    end

    spawned[#spawned + 1] = handle
    return handle
end

local function flush_scheduled()
    vim.wait(20, function()
        return false
    end, 1, false)
end

local ok, err = xpcall(function()
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    typst.project.set_main(main)

    local duplicate = typst.artifact.export({
        outputs = {
            { format = "pdf", output_name = "duplicate" },
            { format = "pdf", output_name = "duplicate" },
        },
    })
    assert(
        duplicate.ok == false and duplicate.reason == "duplicate_output",
        "export should reject duplicate resolved output paths"
    )
    assert(#spawned == 0, "duplicate export should not spawn processes")

    local missing_result = nil
    local missing = typst.artifact.export({
        format = "pdf",
        output_name = "missing",
    }, function(result)
        missing_result = result
    end)
    assert(missing.pending, "missing-output export should start")
    spawned[1]:finish({ code = 0, stdout = "", stderr = "" }, nil)
    flush_scheduled()
    assert(
        missing_result and missing_result.ok == false,
        "exit zero without an artifact should fail export"
    )
    assert(
        missing.artifacts[1].reason == "missing_output",
        "missing artifact should report missing_output"
    )

    local active =
        typst.artifact.export({ format = "pdf", output_name = "active" })
    assert(active.pending, "first active export should start")
    local active_collision =
        typst.artifact.export({ format = "pdf", output_name = "active" })
    assert(
        active_collision.ok == false
            and active_collision.reason == "active_output",
        "second export should reject active output collision"
    )
    spawned[2]:finish({ code = 0, stdout = "", stderr = "" }, "active")
    flush_scheduled()
    assert(active.ok, "first active export should succeed after writing output")

    local first =
        typst.artifact.export({ format = "pdf", output_name = "upsert" })
    spawned[3]:finish({ code = 0, stdout = "", stderr = "" }, "first")
    flush_scheduled()
    assert(first.ok, "first upsert export should succeed")

    local second =
        typst.artifact.export({ format = "pdf", output_name = "upsert" })
    spawned[4]:finish({ code = 0, stdout = "", stderr = "" }, "second")
    flush_scheduled()
    assert(second.ok, "second upsert export should succeed")

    local artifacts = typst.artifact.list({ format = "pdf" })
    local upsert_count = 0
    for _, artifact in ipairs(artifacts) do
        if artifact.path:match("upsert%.pdf$") then
            upsert_count = upsert_count + 1
        end
    end
    assert(
        upsert_count == 1,
        "repeated exports should upsert artifacts by canonical path"
    )

    local same_size_path =
        typst_test_cache_path("export-spec-output/same-size.pdf")
    vim.fn.mkdir(vim.fn.fnamemodify(same_size_path, ":h"), "p")
    vim.fn.writefile({ "aaaa" }, same_size_path)
    vim.uv.fs_utime(same_size_path, 1000, 1000)
    local same_size =
        typst.artifact.export({ format = "pdf", output_name = "same-size" })
    spawned[5]:finish(
        { code = 0, stdout = "", stderr = "" },
        { text = "bbbb", mtime = 1000 }
    )
    flush_scheduled()
    assert(
        same_size.ok,
        "same-size export with unchanged coarse timestamp but changed content should succeed"
    )

    local owned_clean =
        typst.artifact.export({ format = "svg", output_name = "owned-clean" })
    spawned[6]:finish({ code = 0, stdout = "", stderr = "" }, "owned")
    flush_scheduled()
    assert(owned_clean.ok, "owned-clean export should succeed")
    local owned_path = owned_clean.artifacts[1].path
    vim.fn.writefile({ "user changed artifact" }, owned_path)
    local skipped = typst.artifact.clean({ format = "svg" })
    assert(
        skipped.ok == false and #skipped.skipped == 1,
        "artifact clean should skip modified owned artifacts without force"
    )
    assert(
        vim.fn.filereadable(owned_path) == 1,
        "skipped modified artifact should remain on disk"
    )
    local forced = typst.artifact.clean({ format = "svg", force = true })
    assert(forced.ok, "forced artifact clean should delete modified artifact")
    assert(
        vim.fn.filereadable(owned_path) == 0,
        "forced artifact clean should remove modified artifact"
    )

    local compile_done = false
    local compile_handle = typst.compiler.compile({ notify = false }, function()
        compile_done = true
    end)
    assert(compile_handle, "compile should start for cross-producer lease test")
    local spawned_after_compile = #spawned
    local compile_export_collision = typst.artifact.export({ format = "pdf" })
    assert(
        compile_export_collision.ok == false
            and compile_export_collision.reason == "active_output",
        "export should reject an output path currently leased by compile"
    )
    assert(
        #spawned == spawned_after_compile,
        "cross-producer output collision should not spawn export"
    )
    spawned[spawned_after_compile]:finish(
        { code = 0, stdout = "", stderr = "" },
        "compiled"
    )
    flush_scheduled()
    assert(compile_done, "compile should finish after lease collision test")

    local orphan = typst.artifact.export({
        format = "pdf",
        output_name = "orphan-lease",
    })
    assert(orphan.pending, "orphan lease export should start")
    local orphan_handle = spawned[#spawned]
    local orphan_path = orphan.artifacts[1].path
    orphan_handle.kill = function()
        return true
    end
    local cancelled, orphan_cancel_result = orphan.cancel({
        timeout_ms = 0,
        kill_timeout_ms = 0,
    })
    assert(
        not cancelled
            and orphan_cancel_result
            and orphan_cancel_result.stopped == false,
        "orphan lease export should not report a confirmed stop"
    )
    assert(
        orphan.pending
            and orphan.state == "orphaned"
            and orphan.reason == "child_orphaned",
        "orphaned export should remain visibly pending while the child process is owned"
    )
    assert(
        orphan.operations[1].state == "orphaned-retained",
        "failed cancellation should retain the export operation as an orphan"
    )
    assert(
        path_leases.active(orphan_path),
        "orphaned export should retain its output lease until the process exits"
    )
    local orphan_collision = typst.artifact.export({
        format = "pdf",
        output_name = "orphan-lease",
    })
    assert(
        orphan_collision.ok == false
            and orphan_collision.reason == "active_output",
        "export should reject output reuse while an orphan still owns the lease"
    )
    orphan_handle:finish({ code = 1, stdout = "", stderr = "late exit" }, nil)
    flush_scheduled()
    assert(
        orphan.artifacts[1].status == "orphaned",
        "late orphan exit should preserve orphan status instead of plain cancellation"
    )
    assert(
        orphan.pending == false and orphan.state == "orphaned",
        "orphaned export should become non-pending only after the late exit"
    )
    assert(
        not path_leases.active(orphan_path),
        "orphaned export should release its output lease after the late exit"
    )
    local after_orphan = typst.artifact.export({
        format = "pdf",
        output_name = "orphan-lease",
    })
    assert(
        after_orphan.pending,
        "output should be reusable after orphaned export exits"
    )
    spawned[#spawned]:finish({ code = 0, stdout = "", stderr = "" }, "after")
    flush_scheduled()
    assert(after_orphan.ok, "post-orphan export should complete")

    local large_same_size_path =
        typst_test_cache_path("export-spec-output/large-same-size.pdf")
    local coarse_now = os.time()
    local large_before = string.rep("a", 1024 * 1024 + 32)
    local large_after = string.rep("b", #large_before)
    vim.fn.writefile({ large_before }, large_same_size_path)
    vim.uv.fs_utime(large_same_size_path, coarse_now, coarse_now)
    local large_same_size = typst.artifact.export({
        format = "pdf",
        output_name = "large-same-size",
    })
    spawned[#spawned]:finish(
        { code = 0, stdout = "", stderr = "" },
        { text = large_after, mtime = coarse_now }
    )
    flush_scheduled()
    assert(
        large_same_size.ok and large_same_size.artifacts[1].freshness == "mtime",
        "large same-size export with coarse timestamp should be accepted with mtime freshness"
    )

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("export-spec-output"),
        exports = {
            profiles = {
                txt = {
                    format = "txt",
                    output_name = "plain",
                    command = {
                        "fake-text-export",
                        "--from",
                        "{main}",
                        "--to",
                        "{output}",
                        "--format",
                        "{format}",
                        "--profile",
                        "{profile}",
                        "--root",
                        "{root}",
                    },
                    cwd = "{root}",
                    stdout = true,
                },
                cli_options = {
                    format = "html",
                    output_name = "rich",
                    extra_args = { "--custom" },
                    inputs = {
                        theme = "dark",
                        draft = true,
                    },
                    font_paths = { "fonts/a", "fonts/b" },
                    ignore_system_fonts = true,
                    ignore_embedded_fonts = true,
                    package_path = ".typst/packages",
                    package_cache_path = ".typst/cache",
                    creation_timestamp = 123,
                    pretty = true,
                    pages = { "1", "2" },
                    pdf_standard = { "a-2b" },
                    no_pdf_tags = true,
                    ppi = 192,
                    jobs = 1,
                    features = { "html" },
                    diagnostic_format = "short",
                    timings = "timings.json",
                },
                html = {
                    format = "html",
                    output_name = "profile-html",
                    pretty = true,
                    features = { "html" },
                },
            },
        },
    })
    vim.cmd.edit(main)
    typst.project.set_main(main)

    local text_export =
        typst.artifact.export({ profile = "txt", format = "txt" })
    assert(text_export.pending, "custom text export should start")
    local text_handle = spawned[#spawned]
    assert(
        text_handle.opts.cwd == root,
        "custom text export should use placeholder-expanded cwd"
    )
    assert(
        text_handle.command[1] == "fake-text-export",
        "custom text export should run configured command"
    )
    assert(
        text_handle.command[3] == main,
        "custom text export should replace main placeholder"
    )
    assert(
        text_handle.command[5]:match("plain%.txt$"),
        "custom text export should replace output placeholder"
    )
    assert(
        text_handle.command[7] == "txt",
        "custom text export should replace format placeholder"
    )
    assert(
        text_handle.command[9] == "txt",
        "custom text export should replace profile placeholder"
    )
    text_handle:finish({
        code = 0,
        stdout = "plain text export\n",
        stderr = "",
    }, nil)
    flush_scheduled()
    assert(text_export.ok, "custom text export should succeed")
    assert(
        text_export.artifacts[1].format == "txt",
        "custom text export should register txt format"
    )
    assert(
        text_export.artifacts[1].producer == "command",
        "custom text export should register command producer"
    )
    assert(
        table.concat(vim.fn.readfile(text_export.artifacts[1].path), "\n")
            == "plain text export",
        "custom text export should write stdout to the artifact path"
    )

    local cli_export = typst.artifact.export({ profile = "cli_options" })
    assert(cli_export.pending, "CLI options export should start")
    local cli_command = spawned[#spawned].command
    local cli_joined = table.concat(cli_command, "\n")
    for _, expected in ipairs({
        "--custom",
        "--input\ndraft=true",
        "--input\ntheme=dark",
        "--font-path\nfonts/a",
        "--font-path\nfonts/b",
        "--ignore-system-fonts",
        "--ignore-embedded-fonts",
        "--package-path\n.typst/packages",
        "--package-cache-path\n.typst/cache",
        "--creation-timestamp\n123",
        "--pretty",
        "--pages\n1,2",
        "--pdf-standard\na-2b",
        "--no-pdf-tags",
        "--ppi\n192",
        "--jobs\n1",
        "--features\nhtml",
        "--diagnostic-format\nshort",
        "--timings\ntimings.json",
    }) do
        assert(
            cli_joined:find(expected, 1, true),
            ("CLI options export missing %s in %s"):format(
                expected,
                vim.inspect(cli_command)
            )
        )
    end
    spawned[#spawned]:finish({ code = 0, stdout = "", stderr = "" }, "html")
    flush_scheduled()
    assert(cli_export.ok, "CLI options export should succeed")

    local html_profile = typst.artifact.export({ profile = "html" })
    assert(
        html_profile.pending,
        "format-name profile export should start as a profile"
    )
    local html_profile_command = spawned[#spawned].command
    assert(
        html_profile_command[#html_profile_command]:match(
            "profile%-html%.html$"
        ),
        "format-name profile should use profile output_name"
    )
    assert(
        table.concat(html_profile_command, "\n"):find("--pretty", 1, true),
        "format-name profile should use profile CLI options"
    )
    spawned[#spawned]:finish({ code = 0, stdout = "", stderr = "" }, "html")
    flush_scheduled()
    assert(html_profile.ok, "format-name profile export should succeed")

    vim.cmd("TypstExport html")
    local html_command_export = spawned[#spawned].command
    assert(
        html_command_export[#html_command_export]:match("profile%-html%.html$"),
        ":TypstExport should prefer a matching profile over a built-in format"
    )
    spawned[#spawned]:finish({ code = 0, stdout = "", stderr = "" }, "html")
    flush_scheduled()

    local option_output_after =
        stat_signature(vim.uv.fs_stat(option_output_path))
    assert(
        option_output_before == option_output_after,
        "export tests should not write an option-looking ./--version file"
    )
end, debug.traceback)

process.spawn = original_spawn

if not ok then
    error(err)
end

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("artifact-selection"),
})

local artifact_main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(artifact_main)
local artifact_project = typst.project.set_main(artifact_main)

local artifact_services = require("typst.project.services")
local artifact_dir = typst_test_cache_path("artifact-selection")
vim.fn.mkdir(artifact_dir, "p")
local pdf = artifact_dir .. "/main.pdf"
local svg = artifact_dir .. "/main.svg"
vim.fn.writefile({ "pdf" }, pdf)
vim.fn.writefile({ "svg" }, svg)
artifact_services.set_artifacts(artifact_project, {
    items = {
        {
            id = "pdf",
            format = "pdf",
            path = pdf,
            status = "success",
        },
        {
            id = "svg",
            format = "svg",
            path = svg,
            status = "success",
        },
    },
})

local ambiguous = typst.artifact.open({ edit = true })
assert(
    not ambiguous.ok and ambiguous.reason == "ambiguous_artifact",
    "artifact.open should return ambiguity for multiple artifacts"
)
assert(
    #ambiguous.artifacts == 2,
    "ambiguous artifact result should include candidates"
)

local original_select = vim.ui.select
local original_open = vim.ui.open
local selected_prompt = nil
vim.ui.select = function(items, _, callback)
    selected_prompt = items
    callback(items[1])
end
vim.ui.open = function()
    return { wait = function() end }
end
vim.cmd("TypstArtifactOpen")
vim.ui.select = original_select
vim.ui.open = original_open

assert(
    selected_prompt and #selected_prompt == 2,
    "TypstArtifactOpen should prompt when multiple artifacts exist"
)

vim.cmd("qa!")
