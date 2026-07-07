local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local root_discovery = require("typst.project.root")
local registry = require("typst.project")
local typst = require("typst")
local util = require("typst.core.util")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local function write_fixture(name, extras)
    local project_root = typst_test_cache_path(name)
    vim.fn.delete(project_root, "rf")
    vim.fn.mkdir(project_root .. "/chapters", "p")

    local main = util.normalize(project_root .. "/main.typ")
    local leaf = util.normalize(project_root .. "/chapters/leaf.typ")
    vim.fn.writefile({
        "= Deferred Import Scan",
        '#include "chapters/leaf.typ"',
    }, main)
    vim.fn.writefile({ "= Leaf", "Leaf body." }, leaf)
    for index = 1, extras or 40 do
        vim.fn.writefile(
            { ("= Extra %03d"):format(index) },
            ("%s/extra-%03d.typ"):format(project_root, index)
        )
    end
    return project_root, main, leaf
end

local function write_file_limit_fixture(name)
    local project_root = typst_test_cache_path(name)
    vim.fn.delete(project_root, "rf")
    vim.fn.mkdir(project_root .. "/chapters", "p")

    local first_main = util.normalize(project_root .. "/aaa-main.typ")
    local second_main = util.normalize(project_root .. "/zzz-main.typ")
    local leaf = util.normalize(project_root .. "/chapters/leaf.typ")
    vim.fn.writefile({
        "= First",
        '#include "chapters/leaf.typ"',
    }, first_main)
    vim.fn.writefile({
        "= Second",
        '#include "chapters/leaf.typ"',
    }, second_main)
    vim.fn.writefile({ "= Leaf", "Leaf body." }, leaf)
    return project_root, leaf
end

local function setup_for_scan(project_root, extra)
    typst.setup(vim.tbl_deep_extend("force", {
        root_markers = {},
        output_dir = typst_test_cache_path("deferred-import-scan-output"),
        project = {
            import_scan = true,
            import_scan_command_wait_ms = 1,
            import_scan_max_depth = 1,
            import_scan_max_files = 200,
            import_scan_max_entries = 1000,
        },
    }, extra or {}))
end

cleanup()
root_discovery._clear_import_scan_cache()

local ok, err = xpcall(function()
    local project_root, main, leaf =
        write_fixture("deferred-import-scan-budget", 100)
    setup_for_scan(project_root)
    vim.cmd.edit(vim.fn.fnameescape(leaf))
    vim.bo.filetype = "typst"
    local bufnr = vim.api.nvim_get_current_buf()
    typst.project.detach(bufnr)

    local attached = assert(
        typst.project.attach(bufnr),
        "leaf buffer should attach before deferred import scan"
    )
    assert(
        util.same_path(attached.main, leaf),
        "initial attach should use the fast fallback"
    )
    assert(
        attached.resolution_pending == "import_scan",
        "initial attach should expose pending import scan"
    )
    assert(
        root_discovery._import_scan_stats().scans == 0,
        "attach should not run import scan inline"
    )

    local compile_mains = {}
    require("typst.config").unsafe_get().compile.provider = {
        name = "deferred-import-scan-compile-policy",
        output = function(project)
            return util.join(project.root, "out.pdf")
        end,
        compile = function(project, callback)
            compile_mains[#compile_mains + 1] = project.main
            local output = util.join(project.root, "out.pdf")
            vim.fn.writefile(
                { "%PDF-1.4", "% fake deferred scan output" },
                output
            )
            local result = {
                ok = true,
                code = 0,
                output = output,
            }
            if callback then
                callback(result)
            end
            return result
        end,
        start = function(project, callback)
            return require("typst.config")
                .unsafe_get().compile.provider
                .compile(project, callback)
        end,
        stop = function(_project, callback)
            local result = { ok = true, code = 0, stopped = true }
            if callback then
                callback(result)
            end
            return result
        end,
        status = function()
            return "idle"
        end,
    }

    local pending_callbacks = 0
    local pending_result = typst.compiler.compile({}, function(result)
        pending_callbacks = pending_callbacks + 1
        assert(
            result.reason == "resolution_pending",
            "pending compile callback should receive resolution_pending"
        )
    end)
    assert(
        pending_result
            and pending_result.ok == false
            and pending_result.reason == "resolution_pending",
        "compile before deferred scan finishes should fail closed"
    )
    assert(
        pending_callbacks == 1,
        "resolution_pending compile should invoke callback once"
    )
    assert(
        #compile_mains == 0,
        "resolution_pending compile should not invoke provider"
    )

    vim.cmd.enew()
    vim.bo.filetype = "lua"
    local key_pending_callbacks = 0
    local key_pending_result = typst.compiler.compile({
        key = attached.key,
    }, function(result)
        key_pending_callbacks = key_pending_callbacks + 1
        assert(
            result.reason == "resolution_pending",
            "explicit key compile callback should receive resolution_pending"
        )
    end)
    assert(
        key_pending_result
            and key_pending_result.ok == false
            and key_pending_result.reason == "resolution_pending",
        "explicit key compile should also fail closed while project scan is pending"
    )
    assert(
        key_pending_callbacks == 1,
        "explicit key resolution_pending compile should invoke callback once"
    )
    assert(
        #compile_mains == 0,
        "explicit key resolution_pending compile should not invoke provider"
    )
    vim.api.nvim_set_current_buf(bufnr)

    local fallback_result = typst.compiler.compile({
        accept_pending_resolution = true,
    })
    assert(
        fallback_result and fallback_result.ok ~= false,
        "accept_pending_resolution should allow compiling the fallback main"
    )
    assert(
        #compile_mains == 1 and util.same_path(compile_mains[1], leaf),
        "accept_pending_resolution should compile the current fallback main"
    )

    local immediate = assert(
        typst.project.get(bufnr),
        "command-time project lookup should still return a project"
    )
    assert(
        util.same_path(immediate.main, leaf),
        "lookup before scan completion should not force a synchronous scan"
    )

    local suggested = vim.wait(2000, function()
        local current = registry.get(bufnr)
        local resolution = current
            and current.resolutions
            and current.resolutions[bufnr]
        local suggestion = resolution and resolution.import_scan_suggestion
        return current
            and util.same_path(current.main, leaf)
            and current.resolution_pending == nil
            and suggestion
            and util.same_path(suggestion.main, main)
    end, 10)
    assert(suggested, "deferred import scan should record a main suggestion")
    local suggested_project = assert(registry.get(bufnr), "project should live")
    assert(
        util.same_path(suggested_project.main, leaf),
        "deferred suggestion should not reassign the buffer in the background"
    )
    local scan_stats = root_discovery._import_scan_stats()
    assert(scan_stats.scans == 1, "deferred scan should run once")
    assert(scan_stats.last_mode == "deferred", "scan should record mode")
    assert((scan_stats.last_files or 0) > 0, "scan should record file budget")
    assert((scan_stats.last_dirs or 0) > 0, "scan should record directory work")

    local accepted = assert(
        typst.project.get(bufnr),
        "next command-time lookup should accept the suggestion"
    )
    assert(
        util.same_path(accepted.main, main),
        "accepted suggestion should move the buffer to the importing main"
    )
    assert(
        accepted.resolutions[bufnr].import_scan_status == "accepted",
        "accepted suggestion should be visible in resolution metadata"
    )
    local accepted_result = typst.compiler.compile()
    assert(
        accepted_result and accepted_result.ok ~= false,
        "compile after suggestion should run"
    )
    assert(
        util.same_path(compile_mains[#compile_mains], main),
        "compile after suggestion should use the suggested main"
    )

    cleanup()
    root_discovery._clear_import_scan_cache()
    local cancel_root, _, cancel_leaf =
        write_fixture("deferred-import-scan-cancel", 200)
    setup_for_scan(cancel_root)
    vim.cmd.edit(vim.fn.fnameescape(cancel_leaf))
    vim.bo.filetype = "typst"
    bufnr = vim.api.nvim_get_current_buf()
    typst.project.detach(bufnr)
    local cancel_project = assert(typst.project.attach(bufnr))
    assert(cancel_project.resolution_pending == "import_scan")
    typst.project.detach(bufnr)
    vim.wait(200, function()
        return false
    end, 10)
    assert(
        registry.get(bufnr) == nil,
        "detached buffer should not be reassigned by a late deferred scan"
    )

    cleanup()
    root_discovery._clear_import_scan_cache()
    local file_limit_root, file_limit_leaf =
        write_file_limit_fixture("deferred-import-scan-file-limit")
    setup_for_scan(file_limit_root, {
        project = {
            import_scan_max_files = 1,
            import_scan_max_entries = 1000,
        },
    })
    vim.cmd.edit(vim.fn.fnameescape(file_limit_leaf))
    vim.bo.filetype = "typst"
    bufnr = vim.api.nvim_get_current_buf()
    typst.project.detach(bufnr)
    local file_limit_project = assert(typst.project.attach(bufnr))
    assert(file_limit_project.resolution_pending == "import_scan")
    local file_limit_done = vim.wait(2000, function()
        local current = registry.get(bufnr)
        local resolution = current
            and current.resolutions
            and current.resolutions[bufnr]
        return resolution
            and resolution.import_scan_pending == false
            and resolution.import_scan_status == "file_limit"
    end, 10)
    assert(
        file_limit_done,
        "file-limited deferred scan should settle with file_limit"
    )
    local current =
        assert(registry.get(bufnr), "file limit project should live")
    local resolution = current.resolutions and current.resolutions[bufnr]
    assert(
        resolution and resolution.import_scan_suggestion == nil,
        "file-limited scan should not record partial main suggestions"
    )
end, debug.traceback)

cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
