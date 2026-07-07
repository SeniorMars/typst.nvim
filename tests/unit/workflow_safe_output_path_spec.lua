local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local operation = require("typst.core.operation")
local typst = require("typst")

local main = root .. "/tests/fixtures/basic/main.typ"

local function setup_project(opts)
    typst.reset({ force = true })
    opts = vim.tbl_extend("force", {
        root = root,
        output_dir = typst_test_cache_path("workflow-safe-output-path"),
        completion = {
            package_cache_prewarm = false,
        },
    }, opts or {})
    typst.setup(opts)
    vim.cmd.edit(main)
    return typst.project.set_main(main)
end

setup_project()
local export_callbacks = 0
local export_callback_result = nil
local export_result = typst.artifact.export({
    format = "pdf",
    output_name = "../bad-export",
}, function(result)
    export_callbacks = export_callbacks + 1
    export_callback_result = result
end)
assert(
    export_result.ok == false
        and export_result.pending == false
        and export_result.reason == "output_path_invalid",
    "artifact export should return structured invalid output path failures"
)
assert(
    export_callbacks == 1 and export_callback_result == export_result,
    "artifact export invalid output should invoke callback once with returned failure"
)

setup_project()
local render_callbacks = 0
local render_callback_result = nil
local render_result = typst.render.equation({
    expression = "alpha + beta",
    format = "../../../bad-render",
    open = false,
}, function(result)
    render_callbacks = render_callbacks + 1
    render_callback_result = result
end)
assert(
    render_result.ok == false
        and render_result.pending == false
        and render_result.reason == "output_path_invalid",
    "render should return structured invalid output path failures"
)
assert(
    render_callbacks == 1 and render_callback_result == render_result,
    "render invalid output should invoke callback once with returned failure"
)

setup_project()
local render_page_callbacks = 0
local render_page_callback_result = nil
local render_page_result = typst.render.page({
    format = "../../../bad-render-page",
    open = false,
}, function(result)
    render_page_callbacks = render_page_callbacks + 1
    render_page_callback_result = result
end)
assert(
    render_page_result.ok == false
        and render_page_result.pending == false
        and render_page_result.reason == "output_path_invalid"
        and render_page_result.kind == "page",
    "render page should return structured invalid output path failures"
)
assert(
    render_page_callbacks == 1
        and render_page_callback_result == render_page_result,
    "render page invalid output should invoke callback once with returned failure"
)

setup_project({
    compile = {
        profiles = {
            bad_profile_output = {
                output_name = "../bad-profile",
            },
        },
    },
})
local profile_callbacks = 0
local profile_callback_result = nil
local profile_result = typst.development.profile(
    { profile = "bad_profile_output", open = false },
    function(result)
        profile_callbacks = profile_callbacks + 1
        profile_callback_result = result
    end
)
assert(
    profile_result.ok == false
        and profile_result.pending == false
        and profile_result.reason == "output_path_invalid"
        and profile_result.kind == "profile",
    "development profile should return structured invalid output path failures"
)
assert(
    profile_callbacks == 1 and profile_callback_result == profile_result,
    "development profile invalid output should invoke callback once with returned failure"
)

setup_project({
    output_name = "../bad-clean",
})
local clean_result = typst.viewer.clean({ all = true })
assert(
    clean_result.ok == false
        and clean_result.reason == "output_path_invalid"
        and clean_result.output_deleted == false,
    "viewer clean should return structured invalid output path failures"
)

assert(
    vim.tbl_count(operation.active()) == 0,
    "invalid workflow output paths should not start core operations"
)

typst.reset({ force = true })
vim.cmd("qa!")
