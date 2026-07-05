local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local config = require("typst.config")
local process = require("typst.core.process")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("async-cancel-output"),
})
local original_system = process.system
local original_spawn = process.spawn
local original_shutdown = process.shutdown
local original_kill = process.kill
local original_vim_system = vim.system
local handles = {}
local kills = {}
local shutdowns = {}

local function flush_scheduled()
    vim.wait(20, function()
        return false
    end, 1, false)
end

local function reset_fakes()
    handles = {}
    kills = {}
    shutdowns = {}
end

local function make_handle(command, opts, on_exit)
    local handle = {
        id = #handles + 1,
        command = command,
        opts = opts,
        closed = false,
    }

    function handle:is_closing()
        return self.closed
    end

    function handle:finish(result)
        if on_exit then
            on_exit(result or { code = 0, stdout = "", stderr = "" })
        end
    end

    handles[#handles + 1] = handle
    return handle
end

rawset(process, "spawn", function(command, opts, handlers)
    return make_handle(command, opts, handlers and handlers.on_exit)
end)
rawset(process, "system", function(command, opts, on_exit)
    return make_handle(command, opts, on_exit)
end)
rawset(process, "kill", function(handle, signal)
    kills[#kills + 1] = {
        handle = handle,
        signal = signal,
    }
    if handle then
        handle.closed = true
    end
    return true
end)

rawset(process, "shutdown", function(handle, opts)
    shutdowns[#shutdowns + 1] = {
        handle = handle,
        opts = opts,
    }
    if handle then
        handle.closed = true
    end
    return true, {
        stopped = true,
        signal_target = "test",
    }
end)

local ok, err = xpcall(function()
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    typst.project.set_main(main)

    local eval_callback = false
    reset_fakes()
    local eval_result = typst.evaluation.eval(
        { expression = "1 + 1", open = false },
        function()
            eval_callback = true
        end
    )
    assert(
        eval_result.ok and eval_result.pending,
        "eval should start as an async pending result"
    )
    assert(
        type(eval_result.cancel) == "function",
        "eval async result should expose cancel()"
    )
    local stopped =
        eval_result.cancel({ timeout_ms = 1000, kill_timeout_ms = 1000 })
    assert(not stopped, "eval cancel should not report an unconfirmed stop")
    assert(
        eval_result.cancelled
            and eval_result.pending
            and eval_result.state == "cancelling",
        "eval cancel should keep the result pending while shutdown is unconfirmed"
    )
    assert(
        #kills >= 1 and kills[1].handle == handles[1],
        "eval cancel should signal its process handle"
    )
    handles[1]:finish({ code = 0, stdout = "late", stderr = "" })
    flush_scheduled()
    assert(
        eval_result.pending == false and eval_result.state == "cancelled",
        "eval cancel should become non-pending after the process exits"
    )
    assert(
        not eval_callback,
        "late eval exit should not invoke callback after cancel"
    )
    assert(
        eval_result.stdout == nil,
        "late eval exit should not mutate cancelled result output"
    )

    local export_callback = false
    reset_fakes()
    local export_result = typst.artifact.export({
        outputs = {
            { format = "pdf" },
            { format = "svg" },
        },
    }, function()
        export_callback = true
    end)
    assert(
        export_result.ok and export_result.pending,
        "export should start as an async pending result"
    )
    assert(
        type(export_result.cancel) == "function",
        "export async result should expose cancel()"
    )
    stopped = export_result.cancel({
        timeout_ms = 1000,
        kill_timeout_ms = 1000,
    })
    assert(
        not stopped,
        "export cancel should not report stop before artifact processes exit"
    )
    assert(#kills >= 2, "export cancel should signal every artifact handle")
    assert(
        export_result.pending and export_result.state == "cancelling",
        "export cancel should stay pending while child operations are stopping"
    )
    assert(
        export_result.artifacts[1].status == "cancelling",
        "export cancel should mark pending artifacts as cancelling"
    )
    assert(
        export_result.artifacts[2].status == "cancelling",
        "export cancel should mark every pending artifact as cancelling"
    )
    handles[1]:finish({ code = 0, stdout = "", stderr = "" })
    flush_scheduled()
    assert(
        not export_callback,
        "export cancel should wait for every child operation"
    )
    handles[2]:finish({ code = 0, stdout = "", stderr = "" })
    flush_scheduled()
    assert(
        export_callback,
        "export cancel should invoke callback after every child exits: "
            .. vim.inspect({
                completed = export_result.completed,
                pending = export_result.pending,
                cancelled = export_result.cancelled,
                statuses = vim.tbl_map(function(artifact)
                    return artifact.status
                end, export_result.artifacts),
            })
    )
    assert(
        export_result.completed == 2 and export_result.pending == false,
        "cancelled export should finish after all children exit"
    )
    assert(
        export_result.state == "cancelled",
        "cancelled export should report terminal aggregate state after every child exits"
    )

    local render_callback = false
    reset_fakes()
    local render_result = typst.render.fragment(
        { source = "Hello", open = false },
        function()
            render_callback = true
        end
    )
    assert(
        render_result.ok and render_result.pending,
        "render should start as an async pending result"
    )
    assert(
        type(render_result.cancel) == "function",
        "render async result should expose cancel()"
    )
    stopped = render_result.cancel({
        timeout_ms = 1000,
        kill_timeout_ms = 1000,
    })
    assert(
        not stopped and #kills >= 1,
        "render cancel should signal the render process without reporting a confirmed stop"
    )
    handles[1]:finish({ code = 0, stdout = "", stderr = "" })
    flush_scheduled()
    assert(
        render_result.pending == false and render_result.state == "cancelled",
        "render cancel should become non-pending after the process exits"
    )
    assert(
        not render_callback,
        "late render exit should not invoke callback after cancel"
    )

    local init_callback = false
    reset_fakes()
    local init_result = typst.template.init({
        template = "@preview/example:1.0.0",
        destination = typst_test_cache_path("async-cancel-template"),
    }, function()
        init_callback = true
    end)
    assert(
        init_result.ok and init_result.pending,
        "template init should start as an async pending result"
    )
    assert(
        type(init_result.cancel) == "function",
        "template init async result should expose cancel()"
    )
    stopped = init_result.cancel({
        timeout_ms = 1000,
        kill_timeout_ms = 1000,
    })
    assert(
        not stopped and #kills >= 1,
        "template init cancel should signal without reporting a confirmed stop"
    )
    handles[1]:finish({ code = 0, stdout = "", stderr = "" })
    flush_scheduled()
    assert(
        init_result.pending == false and init_result.state == "cancelled",
        "template init cancel should become non-pending after exit"
    )
    assert(
        not init_callback,
        "late template init exit should not invoke callback after cancel"
    )

    local profile_callback = false
    reset_fakes()
    local profile_result = typst.development.profile(
        { open = false },
        function()
            profile_callback = true
        end
    )
    assert(
        profile_result.ok and profile_result.pending,
        "profile should start as an async pending result"
    )
    assert(
        type(profile_result.cancel) == "function",
        "profile async result should expose cancel()"
    )
    stopped = profile_result.cancel({
        timeout_ms = 1000,
        kill_timeout_ms = 1000,
    })
    assert(
        not stopped and #kills >= 1,
        "profile cancel should signal without reporting a confirmed stop"
    )
    handles[1]:finish({ code = 0, stdout = "", stderr = "" })
    flush_scheduled()
    assert(
        profile_result.pending == false and profile_result.state == "cancelled",
        "profile cancel should become non-pending after exit"
    )
    assert(
        not profile_callback,
        "late profile exit should not invoke callback after cancel"
    )

    local test_callback = false
    reset_fakes()
    local test_result = typst.development.test(
        { executable = vim.v.progpath, open = false },
        function()
            test_callback = true
        end
    )
    assert(
        test_result.ok and test_result.pending,
        "test should start as an async pending result"
    )
    assert(
        type(test_result.cancel) == "function",
        "test async result should expose cancel()"
    )
    stopped = test_result.cancel({
        timeout_ms = 1000,
        kill_timeout_ms = 1000,
    })
    assert(
        not stopped and #kills >= 1,
        "test cancel should signal without reporting a confirmed stop"
    )
    handles[1]:finish({ code = 0, stdout = "", stderr = "" })
    flush_scheduled()
    assert(
        test_result.pending == false and test_result.state == "cancelled",
        "test cancel should become non-pending after exit"
    )
    assert(
        not test_callback,
        "late test exit should not invoke callback after cancel"
    )

    config.setup({
        executable = vim.v.progpath,
        root = root,
        output_dir = typst_test_cache_path("async-cancel-output"),
    })
    local registry = require("typst.package.registry")
    reset_fakes()
    registry.reset()
    registry.package_roots()
    assert(
        #handles == 1,
        "package root lookup should start an async typst info probe"
    )
    registry.reset()
    assert(
        #kills >= 1 and kills[1].handle == handles[1],
        "package reset should cancel typst info probe"
    )

    local completion_fonts = require("typst.completion.fonts")
    reset_fakes()
    completion_fonts.reset()
    completion_fonts.items({}, "")
    assert(
        #handles == 1,
        "font completion should start an async typst fonts probe"
    )
    completion_fonts.reset()
    assert(
        #kills >= 1 and kills[1].handle == handles[1],
        "completion reset should cancel typst fonts probe"
    )
    reset_fakes()
    completion_fonts.items({}, "Cached")
    assert(#handles == 1, "font completion should start after reset")
    handles[1]:finish({
        code = 0,
        stdout = "Cached Font\nOther Font\n",
        stderr = "",
    })
    flush_scheduled()
    reset_fakes()
    local cached_font_items = completion_fonts.items({}, "Cached")
    assert(
        #handles == 0,
        "successful font completion scan should be reused from scan cache"
    )
    assert(
        cached_font_items[1] and cached_font_items[1].word == "Cached Font",
        "cached font completion should return scanned font families"
    )

    local metadata_artifacts = require("typst.metadata.artifacts")
    reset_fakes()
    metadata_artifacts.reset()
    metadata_artifacts.detect_typst_version(vim.v.progpath)
    assert(
        #handles == 1,
        "metadata version detection should start an async typst --version probe"
    )
    metadata_artifacts.reset()
    assert(
        #kills >= 1 and kills[1].handle == handles[1],
        "metadata reset should cancel typst --version probe"
    )
end, debug.traceback)

process.system = original_system
process.spawn = original_spawn
process.shutdown = original_shutdown
process.kill = original_kill
vim.system = original_vim_system

if not ok then
    error(err)
end

vim.cmd("qa!")
