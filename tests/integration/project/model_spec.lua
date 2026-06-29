local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_registry = require("typst.project")
local project_services = require("typst.project.services")
local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("project-model-output"),
    compile = {
        profiles = {
            nodeps = {
                deps = false,
            },
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
local chapter = root .. "/tests/fixtures/basic/chapter.typ"
local appendix = root .. "/tests/fixtures/basic/appendix.typ"
local other = root .. "/tests/fixtures/basic/other.typ"

vim.cmd.edit(main)
local main_project = typst.project.set_main(main)

local compiled = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "main project compile failed")
    compiled = true
end)

assert(
    vim.wait(10000, function()
        return compiled
    end, 20),
    "Typst compile did not finish"
)

vim.cmd.edit(chapter)
local chapter_bufnr = vim.api.nvim_get_current_buf()
local chapter_project = typst.project.get(0)
assert(
    chapter_project.key == main_project.key,
    "chapter should attach to main project through dependencies"
)
assert(
    chapter_project.resolutions[chapter_bufnr].main_source
        == "existing project graph",
    "chapter resolution should record dependency graph attachment"
)

vim.cmd.edit(appendix)
local appendix_bufnr = vim.api.nvim_get_current_buf()
local appendix_project = typst.project.get(0)
assert(
    appendix_project.key == main_project.key,
    "appendix should attach to main project through dependencies"
)
assert(
    appendix_project.resolutions[appendix_bufnr].main_source
        == "existing project graph",
    "appendix resolution should record dependency graph attachment"
)

vim.cmd.edit(main)
local nodeps_compiled = false
typst.compiler.compile({ profile = "nodeps" }, function(result)
    assert(result.code == 0, "deps-disabled profile compile failed")
    nodeps_compiled = true
end)

assert(
    vim.wait(10000, function()
        return nodeps_compiled
    end, 20),
    "deps-disabled profile compile did not finish"
)

assert(
    project_services.graph(main_project).dependencies[chapter],
    "deps-disabled compile should preserve previously captured chapter dependency"
)
assert(
    project_services.graph(main_project).dependency_sources[chapter]
        == "compiler",
    "dependency graph should record compiler-discovered chapter dependencies"
)
assert(
    project_services.graph(main_project).file_sources[chapter] == "compiler",
    "project file association should record compiler-discovered chapter dependencies"
)
assert(
    project_services.graph(main_project).dependencies[appendix],
    "deps-disabled compile should preserve previously captured appendix dependency"
)
assert(
    project_services.graph(main_project).dependency_sources[appendix]
        == "compiler",
    "dependency graph should record compiler-discovered appendix dependencies"
)

local stale = root .. "/tests/fixtures/basic/stale.typ"
local graph = project_services.graph(main_project)
graph.dependencies[stale] = true
graph.files[stale] = true
project_registry.update_dependencies(main_project, { main })
graph = project_services.graph(main_project)

assert(
    not graph.dependencies[stale],
    "dependency refresh should drop stale dependency entries"
)
assert(
    not graph.files[stale],
    "dependency refresh should drop stale file index entries"
)
assert(graph.files[chapter], "file index should retain attached chapter buffer")
assert(
    graph.files[appendix],
    "file index should retain attached appendix buffer"
)

vim.cmd.edit(other)
local other_project = typst.project.set_main(other)
assert(
    other_project.key ~= main_project.key,
    "independent document should have a separate project"
)

vim.cmd("qa!")
