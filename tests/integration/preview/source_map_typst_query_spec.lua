local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")

if vim.fn.executable("typst") ~= 1 then
    print("SKIP typst-query source-map test: typst executable not found")
    return
end

typst.reset()
local project_dir = typst_test_cache_path("source-map-typst-query-project")
vim.fn.mkdir(project_dir, "p")

typst.setup({
    root = project_dir,
    preview = {
        source_maps = {
            provider = "typst-query",
        },
    },
})
local main = project_dir .. "/main.typ"
local output = project_dir .. "/main.svg"
local pdf_output = project_dir .. "/main.pdf"
vim.fn.writefile({
    "= Query Sync",
    "",
    "First paragraph for source sync.",
    "",
    "Second unique paragraph for inverse sync.",
}, main)
vim.fn.writefile({
    '<svg viewBox="0 0 595 842" xmlns="http://www.w3.org/2000/svg"></svg>',
}, output)
vim.fn.writefile({ "%PDF-1.7" }, pdf_output)

vim.cmd.edit(main)
local project = typst.project.set_main(main)
local provider = require("typst.preview.source_maps.typst_query")
local source_maps = require("typst.preview.source_maps")
local session = require("typst.preview.native.session")
provider._reset_for_tests()

local svg_route_state = source_maps.route_state(project, {
    output = output,
    generation = "svg",
})
assert(
    svg_route_state.browser_click == true and svg_route_state.available == true,
    "typst-query should advertise browser source sync for SVG output"
)
local pdf_route_state = source_maps.route_state(project, {
    output = pdf_output,
    generation = "pdf",
})
assert(
    pdf_route_state.available == false,
    "typst-query should not advertise source sync for PDF output"
)
assert(
    pdf_route_state.message
        and pdf_route_state.message:find("no SyncTeX%-style source sync"),
    "typst-query PDF state should explain the source-sync limitation"
)

local function finish(handle, label)
    if type(handle) ~= "table" or handle.pending ~= true then
        return handle
    end
    assert(
        vim.wait(10000, function()
            return handle.pending == false
        end, 20),
        label .. " did not finish"
    )
    return handle.result
end

local map = provider.generate({
    key = project.key,
    root = project.root,
    main = project.main,
}, {
    output = output,
    generation = "1",
})
map = finish(map, "typst-query map generation")
assert(map and map.ok == true, map and map.message or "source map failed")
assert(#map.anchors >= 3, "typst-query should map headings and paragraphs")

local paragraph = nil
for _, anchor in ipairs(map.anchors) do
    if anchor.text and anchor.text:find("Second unique paragraph", 1, true) then
        paragraph = anchor
        break
    end
end
assert(paragraph, "typst-query should map the second paragraph text")

local inverse = provider.browser_inverse({
    key = project.key,
    root = project.root,
    main = project.main,
}, {
    output = output,
    generation = "1",
    page = paragraph.page,
    x = paragraph.x,
    y = paragraph.y,
})
inverse = finish(inverse, "typst-query browser inverse")
assert(inverse and inverse.ok == true, "browser inverse should resolve")
assert(inverse.path == main, "browser inverse should resolve the source path")
assert(inverse.line == 5, "browser inverse should resolve the paragraph line")

local forward = provider.forward({
    key = project.key,
    root = project.root,
    main = project.main,
}, {
    output = output,
    generation = "1",
    line = 3,
    column = 1,
})
forward = finish(forward, "typst-query forward")
assert(forward and forward.ok == true, "forward sync should resolve")
assert(forward.line == 3, "forward sync should resolve the requested line")
assert(
    forward.x and forward.y,
    "forward sync should return preview coordinates"
)

session.set_route(project, {
    host = "127.0.0.1",
    port = 65530,
    output = output,
    generation = "service-forward",
    source_sync = {},
})
local service_forward = source_maps.forward(project, {
    line = 5,
    column = 1,
})
assert(
    type(service_forward) == "table" and service_forward.pending == true,
    "source-map service forward should return the provider pending handle"
)
assert(
    vim.wait(10000, function()
        local route = session.route_for_project(project)
        return service_forward.pending == false
            and route ~= nil
            and route.forward_target ~= nil
            and route.forward_target.pending ~= true
    end, 20),
    "source-map service should publish resolved forward target"
)
local target = session.route_for_project(project).forward_target
assert(target.line == 5, "forward target should resolve the requested line")
assert(
    target.x and target.y,
    "forward target should include preview coordinates"
)
session.clear(project)

vim.cmd("qa!")
