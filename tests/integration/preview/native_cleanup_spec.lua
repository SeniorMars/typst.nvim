local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local compiler_service = require("typst.project.services.compiler")
local preview_service = require("typst.project.services.preview")
local project_store = require("typst.project.store")
local server = require("typst.preview.native.server")
local session = require("typst.preview.native.session")
local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        server.reset()
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

local function write_svg(path)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({
        '<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"></svg>',
    }, path)
end

cleanup()

local opened_urls = {}
local ok, err = xpcall(function()
    typst.setup({
        root = root,
        preview = {
            native = "browser",
            follow_buffer = true,
            browser = {
                server = true,
                refresh_ms = 25,
                open = function(url)
                    opened_urls[#opened_urls + 1] = url
                    return true
                end,
            },
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    local chapter = root .. "/tests/fixtures/basic/chapter.typ"
    local first_output = typst_test_cache_path("native-cleanup/first.svg")
    local second_output = typst_test_cache_path("native-cleanup/second.svg")
    write_svg(first_output)
    write_svg(second_output)

    vim.cmd.edit(main)
    local first_snapshot = typst.project.set_main(main)
    local first_project =
        assert(project_store.get(first_snapshot.key), "live first project")
    compiler_service.set(first_project, { output = first_output })
    local opened = typst.viewer.preview_open_browser()
    assert(opened and opened.ok == true, "browser preview should open")
    assert(server.is_running(), "native preview server should be running")
    assert(session.route_count() == 1, "open should register one route")
    assert(
        session.route_for_project(first_project) ~= nil,
        "first project route should exist"
    )

    local original_url = opened_urls[1]
    vim.cmd.edit(chapter)
    local second_snapshot = typst.project.set_main(chapter)
    local second_project =
        assert(project_store.get(second_snapshot.key), "live second project")
    compiler_service.set(second_project, { output = second_output })
    require("typst.preview.follow_buffer").on_buffer(
        vim.api.nvim_get_current_buf()
    )

    assert(
        vim.wait(1000, function()
            local preview = preview_service.get(second_project) or {}
            return preview.active_backend == "native-browser"
                and preview.active_output == second_output
        end, 20),
        "follow_buffer should move browser preview to second project"
    )
    assert(
        #opened_urls == 1,
        "follow_buffer should reuse the active browser URL"
    )
    assert(
        session.route_count() == 1,
        "follow_buffer should keep exactly one server route"
    )
    assert(
        session.route_for_project(first_project) == nil,
        "follow_buffer should remove first project route"
    )
    assert(
        session.browser_url(second_project) == original_url,
        "follow_buffer should keep the route URL stable"
    )
    assert(
        (preview_service.get(first_project) or {}).active ~= true,
        "follow_buffer should clear first project active preview state"
    )
    assert(
        ({ session.clear(first_project) })[1] == nil,
        "clearing old project should not return or remove reassigned route"
    )
    assert(
        session.route_count() == 1,
        "clearing old project should leave reassigned route active"
    )

    typst.viewer.preview_stop({ notify = false })
    assert(
        session.route_count() == 0,
        "preview_stop should clear native routes"
    )
    assert(
        not server.is_running(),
        "preview_stop should stop server when no routes remain"
    )
    assert(
        session.project_state(second_project).active == false,
        "preview_stop should clear session project state"
    )

    opened = typst.viewer.preview_open_browser()
    assert(opened and opened.ok == true, "browser preview should reopen")
    assert(server.is_running(), "reopen should restart server")
    assert(session.route_count() == 1, "reopen should register one route")

    server.reset()
    assert(not server.is_running(), "server.reset should stop server")
    assert(session.route_count() == 0, "server.reset should clear routes")
    assert(
        session.route_for_project(second_project) == nil,
        "server.reset should clear project route lookup"
    )
end, debug.traceback)

cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
