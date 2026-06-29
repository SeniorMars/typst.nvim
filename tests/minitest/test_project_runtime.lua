local MiniTest = require("mini.test")

local helpers = require("tests.minitest.helpers")

local T = MiniTest.new_set()

local function project_attach_status_contract()
    local root = vim.fn.getcwd()
    local typst = require("typst")

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("api-runtime-output"),
    })

    local attach_event = nil
    vim.api.nvim_create_autocmd("User", {
        pattern = "TypstProjectAttach",
        callback = function(args)
            attach_event = args.data
        end,
    })

    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project = assert(typst.project.attach(0), "Typst attach returned nil")

    assert(attach_event, "TypstProjectAttach event was not emitted")
    assert(
        attach_event.key == project.key,
        "TypstProjectAttach event had wrong key"
    )
    assert(
        attach_event.root == project.root,
        "TypstProjectAttach event had wrong root"
    )
    assert(
        attach_event.main == project.main,
        "TypstProjectAttach event had wrong main"
    )
    assert(
        attach_event.output == typst_test_compiler(project).output,
        "TypstProjectAttach event had wrong output"
    )
    assert(
        attach_event.status == typst_test_compiler(project).status,
        "TypstProjectAttach event had wrong status"
    )
    assert(
        attach_event.provider == "typst",
        "TypstProjectAttach event had wrong provider"
    )
    assert(
        attach_event.cwd == project.root,
        "TypstProjectAttach event had wrong cwd"
    )

    local snapshot = typst.ui.status()
    assert(snapshot.attached, "status() should report attached project")
    assert(
        snapshot.key == project.key,
        "status() should report the project key"
    )
    assert(
        type(typst.ui.statusline()) == "string",
        "statusline() should return a string"
    )
end

local function format_callback_contract()
    local root = vim.fn.getcwd()
    local typst = require("typst")

    typst.reset()
    typst.setup({
        root = root,
        output_dir = typst_test_cache_path("api-runtime-output"),
    })

    local reports_api = require("typst.api.reports")
    local operations = require("typst.project.services.operations")

    local original_format = operations.format
    local callback_count = 0
    local notify_count = 0
    local saved_callback = nil

    operations.format = function(_, _, callback)
        saved_callback = callback
        callback({ ok = true, changed = false, provider = "test-format" })
        return { pending = true }
    end

    local ok, err = xpcall(function()
        local api = {
            project = {
                get = function()
                    return { root = root }
                end,
            },
        }

        reports_api.install(api, function()
            notify_count = notify_count + 1
        end)

        local result = api.tools.format({
            notify = false,
            project = { root = root },
        }, function(done)
            callback_count = callback_count + 1
            assert(done.ok, "first formatter completion should be delivered")
        end)

        assert(
            result.pending,
            "wrapper should return the pending operation handle"
        )
        assert(callback_count == 1, "synchronous completion should run once")

        saved_callback({
            ok = false,
            reason = "duplicate",
            message = "duplicate completion",
        })

        assert(
            callback_count == 1,
            "later duplicate completion should not reach user callback"
        )
        assert(notify_count == 0, "notify=false should suppress notifications")
    end, debug.traceback)

    operations.format = original_format

    if not ok then
        error(err)
    end
end

T["emits project attach event and status"] = function()
    helpers.start_child().lua_func(project_attach_status_contract)
end

T["guards synchronous API formatter callbacks"] = function()
    helpers.start_child().lua_func(format_callback_contract)
end

return T
