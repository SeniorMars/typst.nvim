local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local log = require("typst.core.log")
local state_store = require("typst.core.state")
local project_services = require("typst.project.services")
local util = require("typst.core.util")
typst.reset()
typst.setup({
    root = function()
        return root
    end,
    main = function()
        return "tests/fixtures/basic/main.typ"
    end,
    output_dir = typst_test_cache_path("resolution-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
local chapter = root .. "/tests/fixtures/basic/chapter.typ"
local appendix = root .. "/tests/fixtures/basic/appendix.typ"
state_store.clear_explicit_main(chapter)
state_store.clear_explicit_main(appendix)

vim.cmd.edit(chapter)
local configured = typst.project.get(0)
local configured_resolution =
    configured.resolutions[vim.api.nvim_get_current_buf()]
assert(
    configured.root == root,
    "configured root callback should resolve the project root"
)
assert(
    configured.main == main,
    "configured main callback should resolve the main file"
)
assert(
    configured_resolution.root_source == "config.root callback",
    "root source should identify the callback"
)
assert(
    configured_resolution.main_source == "config.main callback",
    "main source should identify the callback"
)

typst.reset()
local callback_error_root = vim.fn.tempname()
vim.fn.mkdir(callback_error_root .. "/.git", "p")
vim.fn.mkdir(callback_error_root .. "/sections", "p")
local callback_error_main = callback_error_root .. "/main.typ"
local callback_error_chapter = callback_error_root .. "/sections/chapter.typ"
vim.fn.writefile(
    { "= Main", '#include "sections/chapter.typ"' },
    callback_error_main
)
vim.fn.writefile({ "= Chapter" }, callback_error_chapter)
typst.setup({
    root = function()
        error("bad root callback")
    end,
    main = function()
        error("bad main callback")
    end,
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan = false,
    },
})

vim.cmd.edit(vim.fn.fnameescape(callback_error_chapter))
vim.b.typst_main = nil
local fallback_after_callback_error = typst.project.get(0)
local fallback_resolution =
    fallback_after_callback_error.resolutions[vim.api.nvim_get_current_buf()]
assert(
    fallback_after_callback_error.root == util.normalize(callback_error_root),
    "throwing root callback should fall back to root markers"
)
assert(
    fallback_after_callback_error.main == util.normalize(callback_error_main),
    "throwing main callback should fall back to root main.typ"
)
assert(
    fallback_resolution.root_source == "root marker .git",
    "throwing root callback should record the fallback root source"
)
assert(
    fallback_resolution.main_source == "root heuristic main.typ",
    "throwing main callback should record the fallback main source"
)

typst.reset()
typst.setup({
    root = function()
        return root
    end,
    main = function()
        return "tests/fixtures/basic/main.typ"
    end,
    output_dir = typst_test_cache_path("resolution-output"),
})

vim.b.typst_main = appendix
typst.project.detach(0)
local buffer_local = typst.project.get(0)
local buffer_local_resolution =
    buffer_local.resolutions[vim.api.nvim_get_current_buf()]
assert(
    buffer_local.main == appendix,
    "buffer-local main should override config.main"
)
assert(
    buffer_local_resolution.main_source == "buffer variable vim.b.typst_main",
    "main source should identify vim.b.typst_main"
)

typst.reset()
typst.setup({
    root = root,
    main = {
        [root] = "tests/fixtures/basic/main.typ",
    },
    output_dir = typst_test_cache_path("resolution-output"),
})

vim.cmd.edit(chapter)
vim.b.typst_main = nil
local mapped = typst.project.get(0)
local mapped_resolution = mapped.resolutions[vim.api.nvim_get_current_buf()]
assert(
    mapped.main == main,
    "per-root main mapping should resolve the configured main file"
)
assert(
    mapped_resolution.root_source == "config.root",
    "mapped root source should identify config.root"
)
assert(
    mapped_resolution.main_source == "config.main table",
    "main source should identify config.main table"
)

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan = false,
    },
})

vim.cmd.edit(chapter)
vim.b.typst_main = nil
local standalone = typst.project.get(0)
local standalone_resolution =
    standalone.resolutions[vim.api.nvim_get_current_buf()]
assert(
    standalone.main == chapter,
    "missing main.typ should fall back to the current buffer"
)
assert(
    standalone_resolution.root_source == "config.root",
    "root source should identify config.root"
)
assert(
    standalone_resolution.main_source == "current buffer",
    "main source should identify current-buffer fallback"
)

vim.b.typst_main = main
local remapped = typst.project.get(0)
local remapped_resolution = remapped.resolutions[vim.api.nvim_get_current_buf()]
assert(
    remapped.key ~= standalone.key,
    "changed buffer-local main should move the buffer to another project"
)
assert(
    remapped.main == main,
    "changed buffer-local main should be honored by get_project"
)
assert(
    remapped_resolution.main_source == "buffer variable vim.b.typst_main",
    "changed buffer-local main should update the resolution source"
)

typst.reset()
local fixture_root = root .. "/tests/fixtures/basic"
typst.setup({
    root_markers = { ".git" },
    main = {
        [fixture_root] = "main.typ",
    },
    output_dir = typst_test_cache_path("resolution-output"),
})

vim.cmd.edit(chapter)
vim.b.typst_main = nil
local mapped_root = typst.project.get(0)
local mapped_root_resolution =
    mapped_root.resolutions[vim.api.nvim_get_current_buf()]
assert(
    mapped_root.root == fixture_root,
    "per-root main mapping should choose the matching subproject root"
)
assert(
    mapped_root.main == main,
    "per-root main mapping should resolve relative to the chosen subproject root"
)
assert(
    mapped_root_resolution.root_source == "config.main table root",
    "root source should identify roots inferred from config.main table"
)
assert(
    mapped_root_resolution.main_source == "config.main table",
    "main source should still identify config.main table"
)

typst.reset()
local multi_main_root = vim.fn.tempname()
vim.fn.mkdir(multi_main_root .. "/.git", "p")
vim.fn.mkdir(multi_main_root .. "/sections", "p")
local multi_main = multi_main_root .. "/main.typ"
local multi_report = multi_main_root .. "/report.typ"
local multi_chapter = multi_main_root .. "/sections/chapter.typ"
vim.fn.writefile({ "= Main", '#include "sections/chapter.typ"' }, multi_main)
vim.fn.writefile({ "= Report" }, multi_report)
vim.fn.writefile({ "= Chapter" }, multi_chapter)
typst.setup({
    root_markers = { ".git" },
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan = false,
    },
})

vim.cmd.edit(vim.fn.fnameescape(multi_main))
vim.b.typst_main = nil
local multi_main_project = typst.project.get(0)
local multi_main_resolution =
    multi_main_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    multi_main_project.root == util.normalize(multi_main_root),
    "Git marker should define the shared root"
)
assert(
    multi_main_project.main == util.normalize(multi_main),
    "top-level main.typ should resolve as itself"
)
assert(
    multi_main_resolution.main_source == "current buffer",
    "top-level main.typ should record current-buffer resolution"
)

vim.cmd.edit(vim.fn.fnameescape(multi_report))
vim.b.typst_main = nil
local multi_report_project = typst.project.get(0)
local multi_report_resolution =
    multi_report_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    multi_report_project.root == multi_main_project.root,
    "independent mains should share the Git root"
)
assert(
    multi_report_project.key ~= multi_main_project.key,
    "independent root-level mains should use distinct projects"
)
assert(
    multi_report_project.main == util.normalize(multi_report),
    "root-level report should not silently attach to root main.typ"
)
assert(
    multi_report_resolution.main_source == "current buffer",
    "independent root-level mains should record current-buffer resolution"
)

vim.cmd.edit(vim.fn.fnameescape(multi_chapter))
vim.b.typst_main = nil
local multi_chapter_project = typst.project.get(0)
local multi_chapter_resolution =
    multi_chapter_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    multi_chapter_project.main == util.normalize(multi_main),
    "nested files should still fall back to root main.typ"
)
assert(
    multi_chapter_resolution.main_source == "root heuristic main.typ",
    "nested root-main fallback should keep the heuristic source"
)

typst.reset()
local directive_root = vim.fn.tempname()
vim.fn.mkdir(directive_root .. "/chapters", "p")
local directive_main = directive_root .. "/main.typ"
local directive_chapter = directive_root .. "/chapters/chapter.typ"
vim.fn.writefile(
    { "= Main", '#include "chapters/chapter.typ"' },
    directive_main
)
vim.fn.writefile(
    { "// typst.nvim: main = ../main.typ", "= Chapter" },
    directive_chapter
)
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
})

vim.cmd.edit(vim.fn.fnameescape(directive_chapter))
vim.b.typst_main = nil
local directive_project = typst.project.get(0)
local directive_resolution =
    directive_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    directive_project.root == util.normalize(directive_root),
    "directive main should promote the fallback root"
)
assert(
    directive_project.main == util.normalize(directive_main),
    "Typst comment directive should resolve the main file"
)
assert(
    directive_resolution.root_source
        == "Typst directive typst.nvim: main common root",
    "directive root source should explain the inferred common root"
)
assert(
    directive_resolution.main_source == "Typst directive typst.nvim: main",
    "directive main source should identify the Typst comment"
)

typst.reset()
local project_file_root = vim.fn.tempname()
vim.fn.mkdir(project_file_root .. "/sections", "p")
local project_file_main = project_file_root .. "/document.typ"
local project_file_chapter = project_file_root .. "/sections/chapter.typ"
vim.fn.writefile(
    { "# fixture project main", "main = document.typ" },
    project_file_root .. "/.typstmain"
)
vim.fn.writefile(
    { "= Document", '#include "sections/chapter.typ"' },
    project_file_main
)
vim.fn.writefile({ "= Chapter" }, project_file_chapter)
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
})

vim.cmd.edit(vim.fn.fnameescape(project_file_chapter))
vim.b.typst_main = nil
local project_file_project = typst.project.get(0)
local project_file_resolution =
    project_file_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    project_file_project.root == util.normalize(project_file_root),
    ".typstmain should define the project root"
)
assert(
    project_file_project.main == util.normalize(project_file_main),
    ".typstmain should resolve the main file"
)
assert(
    project_file_resolution.root_source == ".typstmain project file",
    ".typstmain root source should identify the project file"
)
assert(
    project_file_resolution.main_source == ".typstmain project file",
    ".typstmain main source should identify the project file"
)

typst.reset()
local scan_root = vim.fn.tempname()
vim.fn.mkdir(scan_root .. "/chapters", "p")
local scan_main = scan_root .. "/document.typ"
local scan_fake_main = scan_root .. "/main.typ"
local scan_chapter = scan_root .. "/chapters/chapter.typ"
vim.fn.writefile(
    { "= Document", 'Don\'t hide #include "chapters/chapter.typ"' },
    scan_main
)
vim.fn.writefile({
    "= Fake",
    '// #include "chapters/chapter.typ"',
    '#let fake = "#include \\"chapters/chapter.typ\\""',
    'Inline raw: `#include "chapters/chapter.typ"`',
    "/*",
    '#include "chapters/chapter.typ"',
    "*/",
    "```typ",
    '#include "chapters/chapter.typ"',
    "```",
}, scan_fake_main)
vim.fn.writefile({ "= Chapter" }, scan_chapter)
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan_max_depth = 2,
    },
})

vim.cmd.edit(vim.fn.fnameescape(scan_chapter))
vim.b.typst_main = nil
local scan_project = typst.project.get(0)
local scan_resolution = scan_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    scan_project.root == util.normalize(scan_root),
    "import scan should infer the referencing project root"
)
assert(
    scan_project.main == util.normalize(scan_main),
    "import scan should resolve the referencing main file"
)
assert(
    scan_project.main ~= util.normalize(scan_fake_main),
    "import scan should ignore non-code references"
)
assert(
    scan_resolution.root_source == "import scan root",
    "import scan root source should identify the fallback"
)
assert(
    scan_resolution.main_source == "import scan",
    "import scan main source should identify the fallback"
)
assert(
    project_services.graph(scan_project).file_sources[util.normalize(
        scan_chapter
    )] == "heuristic",
    "import scan should record a heuristic project association for the opened dependency"
)

typst.reset()
local dot_scan_root = vim.fn.tempname()
vim.fn.mkdir(dot_scan_root .. "/.hidden-project-cache", "p")
local dot_scan_leaf = dot_scan_root .. "/leaf.typ"
local dot_scan_main = dot_scan_root .. "/.hidden-project-cache/main.typ"
vim.fn.writefile({ "= Leaf" }, dot_scan_leaf)
vim.fn.writefile({ "= Main", '#include "../leaf.typ"' }, dot_scan_main)
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan_max_depth = 1,
    },
})

vim.cmd.edit(vim.fn.fnameescape(dot_scan_leaf))
vim.b.typst_main = nil
local dot_scan_project = typst.project.get(0)
assert(
    dot_scan_project.root == util.normalize(dot_scan_root),
    "import scan should not treat ordinary hidden directories as skipped roots"
)
assert(
    dot_scan_project.main == util.normalize(dot_scan_main),
    "import scan should find Typst mains under ordinary dot directories"
)

typst.reset()
local ambiguous_root = vim.fn.tempname()
vim.fn.mkdir(ambiguous_root .. "/chapters", "p")
local ambiguous_thesis = ambiguous_root .. "/thesis.typ"
local ambiguous_slides = ambiguous_root .. "/slides.typ"
local ambiguous_chapter = ambiguous_root .. "/chapters/intro.typ"
vim.fn.writefile(
    { "= Thesis", '#include "chapters/intro.typ"' },
    ambiguous_thesis
)
vim.fn.writefile(
    { "= Slides", '#include "chapters/intro.typ"' },
    ambiguous_slides
)
vim.fn.writefile({ "= Intro" }, ambiguous_chapter)
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan_max_depth = 2,
    },
})

vim.cmd.edit(vim.fn.fnameescape(ambiguous_chapter))
vim.b.typst_main = nil
local ambiguous_project = typst.project.get(0)
local ambiguous_resolution =
    ambiguous_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    ambiguous_project.main == util.normalize(ambiguous_chapter),
    "ambiguous import scan should fall back to the current buffer"
)
assert(
    ambiguous_resolution.main_source == "current buffer",
    "ambiguous import scan should not silently choose the first candidate"
)

typst.reset()
log.clear()
local exact_limit_root = vim.fn.tempname()
vim.fn.mkdir(exact_limit_root .. "/aaa-empty", "p")
local exact_limit_leaf = exact_limit_root .. "/leaf.typ"
vim.fn.writefile({ "= Leaf" }, exact_limit_leaf)
vim.fn.writefile({ "= Other" }, exact_limit_root .. "/other.typ")
vim.fn.writefile({ "not typst" }, exact_limit_root .. "/aaa-empty/note.txt")
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan = true,
        import_scan_max_files = 2,
        import_scan_max_depth = 0,
    },
})

vim.cmd.edit(vim.fn.fnameescape(exact_limit_leaf))
vim.b.typst_main = nil
typst.project.get(0)
for _, entry in ipairs(log.entries()) do
    assert(
        entry.message ~= "import scan reached Typst file limit",
        "import scan should not log a limit hit when the scan ended exactly at the limit"
    )
end

typst.reset()
log.clear()
local limit_root = vim.fn.tempname()
vim.fn.mkdir(limit_root, "p")
local limit_leaf = limit_root .. "/leaf.typ"
vim.fn.writefile({ "= Leaf" }, limit_leaf)
vim.fn.writefile({ "= First" }, limit_root .. "/first.typ")
vim.fn.writefile({ "= Second" }, limit_root .. "/second.typ")
vim.fn.writefile({ "= Third" }, limit_root .. "/third.typ")
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan = true,
        import_scan_max_files = 2,
        import_scan_max_depth = 0,
    },
})

vim.cmd.edit(vim.fn.fnameescape(limit_leaf))
vim.b.typst_main = nil
typst.project.get(0)
local saw_scan_limit = false
for _, entry in ipairs(log.entries()) do
    if
        entry.message == "import scan reached Typst file limit"
        and entry.fields
        and entry.fields.limit == 2
        and entry.fields.root == util.normalize(limit_root)
    then
        saw_scan_limit = true
        break
    end
end
assert(saw_scan_limit, "import scan should log when it reaches its file limit")

typst.reset()
local unicode_root = vim.fn.tempname() .. " spaced α"
vim.fn.mkdir(unicode_root .. "/chapters and figures", "p")
local unicode_main = unicode_root .. "/main document.typ"
local unicode_chapter = unicode_root
    .. "/chapters and figures/über chapter.typ"
vim.fn.writefile(
    { "= Main", '#include "chapters and figures/über chapter.typ"' },
    unicode_main
)
vim.fn.writefile({ "= Über Chapter", "<sec:über>" }, unicode_chapter)
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan = true,
        import_scan_max_files = 20,
        import_scan_max_depth = 2,
    },
})

vim.cmd.edit(vim.fn.fnameescape(unicode_chapter))
vim.b.typst_main = nil
local unicode_project = typst.project.get(0)
local unicode_resolution =
    unicode_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    unicode_project.root == util.normalize(unicode_root),
    "import scan should preserve roots containing spaces and Unicode"
)
assert(
    unicode_project.main == util.normalize(unicode_main),
    "import scan should resolve main files containing spaces"
)
assert(
    unicode_resolution.main_source == "import scan",
    "Unicode path import scan should record its source"
)
assert(
    project_services.graph(unicode_project).file_sources[util.normalize(
        unicode_chapter
    )] == "heuristic",
    "Unicode path dependency should keep its heuristic association"
)
local unicode_label_seen = false
for _, item in ipairs(typst.index.labels(unicode_project)) do
    if
        item.name == "sec:über"
        and item.source.path == util.normalize(unicode_chapter)
    then
        unicode_label_seen = true
        break
    end
end
assert(
    unicode_label_seen,
    "project index should scan included files with spaces and Unicode paths"
)

vim.cmd.edit(vim.fn.fnameescape(scan_chapter))
vim.b.typst_main = nil
scan_project = typst.project.get(0)

local local_toggle = typst.project.toggle_main({ notify = false })
assert(
    local_toggle.local_main == true,
    "toggle_main should enable local-main mode"
)
assert(
    local_toggle.state.main == util.normalize(scan_chapter),
    "local-main mode should use the current buffer as main"
)
assert(
    vim.b.typst_main == util.normalize(scan_chapter),
    "toggle_main should store the current buffer in vim.b.typst_main"
)

local project_toggle = typst.project.toggle_main({ notify = false })
assert(
    project_toggle.local_main == false,
    "toggle_main should disable local-main mode"
)
assert(
    project_toggle.state.main == util.normalize(scan_main),
    "toggle_main should restore project main resolution"
)
assert(
    vim.b.typst_main == nil,
    "toggle_main should clear vim.b.typst_main when returning to project mode"
)

local toggle_link = scan_root .. "/chapters/chapter-link.typ"
if (vim.uv or vim.loop).fs_symlink(scan_chapter, toggle_link) then
    vim.b.typst_main = toggle_link
    local linked_toggle = typst.project.toggle_main({ notify = false })
    assert(
        linked_toggle.local_main == false,
        "toggle_main should clear local-main mode when vim.b.typst_main is an equivalent canonical path"
    )
    assert(
        vim.b.typst_main == nil,
        "equivalent canonical local-main toggle should clear vim.b.typst_main"
    )
end

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("resolution-output"),
    project = {
        import_scan = false,
    },
})

vim.cmd.edit(vim.fn.fnameescape(scan_chapter))
vim.b.typst_main = nil
local no_scan_project = typst.project.get(0)
local no_scan_resolution =
    no_scan_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    no_scan_project.main == util.normalize(scan_chapter),
    "disabled import scan should fall back to current buffer"
)
assert(
    no_scan_resolution.main_source == "current buffer",
    "disabled import scan should not affect resolution source"
)

vim.cmd("qa!")
