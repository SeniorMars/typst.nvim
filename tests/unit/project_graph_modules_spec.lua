local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_dependencies = require("typst.project.dependencies")
local graph_dependencies = require("typst.project.graph.dependencies")
local graph_sources = require("typst.project.graph.sources")
local index_files = require("typst.project.index_files")
local index_traversal = require("typst.project.index_traversal")
local project_model = require("typst.project.model")
local project_services = require("typst.project.services")
local util = require("typst.core.util")

local ok, err = xpcall(function()
    local main = root .. "/tests/fixtures/basic/main.typ"
    local chapter = root .. "/tests/fixtures/basic/chapter.typ"
    local asset = root .. "/tests/fixtures/basic/figure.png"
    local project = project_model.new_project(
        root,
        main,
        project_model.project_key(root, main)
    )

    assert(
        graph_sources.source_priority("explicit")
            > graph_sources.source_priority("compiler"),
        "explicit graph sources should outrank compiler sources"
    )
    assert(
        project_model.source_priority("compiler")
            == graph_sources.source_priority("compiler"),
        "project model source-priority compatibility should delegate"
    )
    assert(type(index_files.read_lines) == "function", "index files module")
    assert(
        type(index_traversal.collect) == "function",
        "index traversal module"
    )
    for _, removed in ipairs({
        "typst.project.index.aggregate",
        "typst.project.index.cache",
        "typst.project.index.files",
        "typst.project.index.path_calls",
        "typst.project.index.paths",
        "typst.project.index.providers",
        "typst.project.index.scanner",
        "typst.project.index.scanner_glossary",
        "typst.project.index.scanner_helpers",
        "typst.project.index.traversal",
    }) do
        assert(
            not pcall(require, removed),
            removed .. " should not remain as a one-line compatibility alias"
        )
    end

    local changed =
        graph_dependencies.replace(project, { main, chapter, asset })
    assert(changed, "first dependency replacement should mark graph changed")
    project_model.rebuild_files(project)

    local graph = assert(project_services.graph(project))
    assert(graph.dependencies[asset], "asset should remain a dependency")
    assert(
        not graph.files[asset],
        "asset dependency should not become an indexed Typst source"
    )
    assert(
        graph.files[chapter],
        ".typ dependency should remain an indexed source"
    )
    assert(
        graph.file_sources[chapter] == "compiler",
        ".typ dependency source should record compiler ownership"
    )

    changed = graph_dependencies.replace(project, { main, chapter, asset })
    assert(not changed, "same dependency replacement should not mark changed")

    local workdir = typst_test_cache_path("index-dependency-sources")
    vim.fn.delete(workdir, "rf")
    vim.fn.mkdir(workdir, "p")

    local indexed_main = util.normalize(workdir .. "/main.typ")
    local indexed_chapter = util.normalize(workdir .. "/chapter.typ")
    local figure = util.normalize(workdir .. "/figure.png")
    local data = util.normalize(workdir .. "/data.csv")
    local refs = util.normalize(workdir .. "/refs.bib")
    local huge = util.normalize(workdir .. "/huge.typ")

    vim.fn.writefile({ '#include "chapter.typ"' }, indexed_main)
    vim.fn.writefile({ "= Chapter" }, indexed_chapter)
    vim.fn.writefile({ "not really a png" }, figure)
    vim.fn.writefile({ "value,1" }, data)
    vim.fn.writefile({ "@book{key,title={Title}}" }, refs)
    vim.fn.writefile({ ("x"):rep(1024 * 1024 + 32) .. "<huge-label>" }, huge)

    local indexed_project = {
        key = "index-dependency-sources",
        root = workdir,
        main = indexed_main,
        bufs = {},
        services = project_services.new_state(),
    }

    project_dependencies.update(indexed_project, {
        indexed_main,
        indexed_chapter,
        huge,
        figure,
        data,
        refs,
    })
    local files = index_files.initial_files(indexed_project)
    local by_key = {}
    for _, path in ipairs(files) do
        by_key[util.path_key(path)] = true
    end

    assert(
        by_key[util.path_key(indexed_main)],
        "index should include project main"
    )
    assert(
        by_key[util.path_key(indexed_chapter)],
        "index should include .typ dependencies"
    )
    assert(by_key[util.path_key(huge)], "index should retain .typ dependencies")
    assert(
        not by_key[util.path_key(figure)],
        "index should not scan image dependencies as Typst source"
    )
    assert(
        not by_key[util.path_key(data)],
        "index should not scan data dependencies as Typst source"
    )
    assert(
        not by_key[util.path_key(refs)],
        "index should not scan bibliography dependencies as Typst source"
    )
    assert(
        project_services.graph(indexed_project).dependencies[figure],
        "asset dependencies should still be retained for invalidation"
    )

    local traversal = index_traversal.collect(indexed_project)
    local huge_record = nil
    for _, record in ipairs(traversal.records or {}) do
        if util.same_path(record.path, huge) then
            huge_record = record
            break
        end
    end

    assert(
        huge_record,
        "large .typ dependency should still produce a cache record"
    )
    assert(
        #huge_record.data.labels == 0,
        "large unloaded .typ dependency should be skipped instead of scanned"
    )
end, debug.traceback)

if not ok then
    error(err)
end

print("project_graph_modules_spec: ok")
