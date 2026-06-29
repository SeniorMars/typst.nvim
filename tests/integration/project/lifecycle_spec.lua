local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local registry = require("typst.project")
local project_services = require("typst.project.services")
local typst = require("typst")
local util = require("typst.core.util")
local uv = vim.uv or vim.loop

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-lifecycle-output"),
    project = {
        import_scan = false,
    },
})

vim.cmd.enew()
local scratch_bufnr = vim.api.nvim_get_current_buf()
vim.bo.filetype = "typst"
vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, { "= Unsaved" })

local scratch_project = assert(
    typst.project.attach(scratch_bufnr),
    "unnamed Typst buffers should attach"
)
assert(
    scratch_project.root == util.normalize(root),
    "unnamed buffer project should use cwd as root"
)
local scratch_dir = util.join(vim.fn.stdpath("cache"), "typst.nvim", "unsaved")
assert(
    scratch_project.main:find(scratch_dir, 1, true) == 1
        and scratch_project.main:match(
            "unsaved[/\\][^/\\]+[/\\]buffer%-%d+%-%d+%.typ$"
        ),
    "unnamed buffer should use an XDG cache scratch main path"
)
assert(
    scratch_project.bufs[scratch_bufnr],
    "scratch project should own the unnamed buffer"
)
assert(
    scratch_project.resolutions[scratch_bufnr].main_source == "unnamed buffer",
    "scratch resolution should record unnamed-buffer source"
)
assert(
    scratch_project.resolutions[scratch_bufnr].scratch == true,
    "scratch resolution should be marked"
)

local saved_from_scratch = vim.fn.tempname() .. ".typ"
vim.cmd("silent saveas " .. vim.fn.fnameescape(saved_from_scratch))
local saved_project = typst.project.get(scratch_bufnr)
assert(
    saved_project.main == util.normalize(saved_from_scratch),
    "saveas should move scratch buffer to real file main"
)
assert(
    saved_project.key ~= scratch_project.key,
    "saveas should move scratch buffer to a real project key"
)
assert(
    saved_project.bufs[scratch_bufnr],
    "saved project should own the saved buffer"
)
assert(
    registry.all()[scratch_project.key] == nil,
    "empty scratch project should be pruned after saveas"
)

local fixture_root = vim.fn.tempname()
vim.fn.mkdir(fixture_root, "p")
local original = fixture_root .. "/draft.typ"
local renamed = fixture_root .. "/renamed.typ"
vim.fn.writefile({ "= Draft" }, original)

vim.cmd.edit(vim.fn.fnameescape(original))
vim.bo.filetype = "typst"
local initial = typst.project.attach(0)
local bufnr = vim.api.nvim_get_current_buf()

assert(
    initial.main == util.normalize(original),
    "current-buffer project should use the original file as main"
)
assert(
    project_services.graph(initial).files[util.normalize(original)],
    "initial project should index the original buffer path"
)

vim.cmd("silent saveas " .. vim.fn.fnameescape(renamed))

local moved = typst.project.get(bufnr)
assert(
    moved.main == util.normalize(renamed),
    "BufFilePost should re-resolve the renamed buffer main"
)
assert(
    moved.key ~= initial.key,
    "renamed current-buffer project should move to a new project key"
)
assert(moved.bufs[bufnr], "renamed project should own the buffer")
assert(
    project_services.graph(moved).files[util.normalize(renamed)],
    "renamed project should index the new buffer path"
)
assert(
    not project_services.graph(moved).files[util.normalize(original)],
    "renamed project should not keep the stale buffer path"
)
assert(
    registry.all()[initial.key] == nil,
    "empty project from the old buffer path should be pruned"
)

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-lifecycle-output"),
    project = {
        import_scan = false,
    },
})

local shared_root = vim.fn.tempname()
vim.fn.mkdir(shared_root, "p")
local shared = shared_root .. "/shared.typ"
local main_a = shared_root .. "/main-a.typ"
local main_b = shared_root .. "/main-b.typ"
vim.fn.writefile({ "= Shared" }, shared)
vim.fn.writefile({ "= Main A", '#include "shared.typ"' }, main_a)
vim.fn.writefile({ "= Main B", '#include "shared.typ"' }, main_b)

vim.cmd.edit(vim.fn.fnameescape(main_a))
local project_a = typst.project.set_main(main_a)
registry.update_dependencies(project_a, { main_a, shared })

vim.cmd.edit(vim.fn.fnameescape(main_b))
local project_b = typst.project.set_main(main_b)
registry.update_dependencies(project_b, { main_b, shared })

vim.cmd.edit(vim.fn.fnameescape(shared))
vim.b.typst_main = nil
local shared_project = typst.project.get(0)
local shared_bufnr = vim.api.nvim_get_current_buf()
assert(
    shared_project.key ~= project_a.key,
    "shared file should not silently attach to the first project graph"
)
assert(
    shared_project.key ~= project_b.key,
    "shared file should not silently attach to the second project graph"
)
assert(
    shared_project.main == util.normalize(shared),
    "ambiguous shared file should fall back to its own buffer project"
)
assert(
    shared_project.resolutions[shared_bufnr].main_source == "current buffer",
    "ambiguous shared file should record the fallback resolution source"
)

vim.b.typst_main = main_a
local explicit_project = typst.project.get(0)
assert(
    explicit_project.key == project_a.key,
    "explicit buffer main should override ambiguous project graphs"
)
assert(
    explicit_project.resolutions[shared_bufnr].main_source
        == "buffer variable vim.b.typst_main",
    "explicit shared-file resolution should record vim.b.typst_main as the source"
)

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-lifecycle-output"),
    project = {
        import_scan = false,
    },
})

local source_root = vim.fn.tempname()
vim.fn.mkdir(source_root, "p")
local source_shared = source_root .. "/shared.typ"
local heuristic_main = source_root .. "/heuristic-main.typ"
local compiler_main = source_root .. "/compiler-main.typ"
vim.fn.writefile({ "= Shared" }, source_shared)
vim.fn.writefile({ "= Heuristic", '#include "shared.typ"' }, heuristic_main)
vim.fn.writefile({ "= Compiler", '#include "shared.typ"' }, compiler_main)

vim.cmd.edit(vim.fn.fnameescape(heuristic_main))
local heuristic_project = typst.project.set_main(heuristic_main)
registry.update_dependencies(
    heuristic_project,
    { heuristic_main, source_shared },
    { source = "heuristic" }
)

vim.cmd.edit(vim.fn.fnameescape(compiler_main))
local compiler_project = typst.project.set_main(compiler_main)
registry.update_dependencies(compiler_project, { compiler_main, source_shared })

vim.cmd.edit(vim.fn.fnameescape(source_shared))
vim.b.typst_main = nil
local sourced_project = typst.project.get(0)
local source_resolution =
    sourced_project.resolutions[vim.api.nvim_get_current_buf()]
assert(
    sourced_project.key == compiler_project.key,
    "compiler-discovered project graph should outrank heuristic associations"
)
assert(
    source_resolution.graph_source == "compiler",
    "existing project graph resolution should record graph source"
)
assert(
    project_services.graph(heuristic_project).file_sources[util.normalize(
        source_shared
    )] == "heuristic",
    "heuristic project graph should preserve its association source"
)
assert(
    project_services.graph(compiler_project).dependency_sources[util.normalize(
        source_shared
    )] == "compiler",
    "compiler project graph should preserve its association source"
)

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-lifecycle-output"),
    project = {
        import_scan = false,
    },
})

local symlink_root = vim.fn.tempname()
vim.fn.mkdir(symlink_root, "p")
local canonical_main = symlink_root .. "/canonical.typ"
local linked_main = symlink_root .. "/linked.typ"
vim.fn.writefile({ "= Canonical" }, canonical_main)
local symlink_ok = uv.fs_symlink(canonical_main, linked_main)
if symlink_ok then
    vim.cmd.edit(vim.fn.fnameescape(linked_main))
    local symlink_project = typst.project.attach(0)
    local lexical_link = vim.fs.normalize(vim.fn.fnamemodify(linked_main, ":p"))
    local canonical = util.normalize(canonical_main)
    assert(
        symlink_project.main == canonical,
        "symlinked buffers should resolve to the canonical main path"
    )
    assert(
        project_services.graph(symlink_project).files[canonical],
        "canonical project file index should include the real path"
    )
    if lexical_link ~= canonical then
        assert(
            symlink_project.main ~= lexical_link,
            "project keys should not use the lexical symlink path"
        )
    end
end

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-lifecycle-output"),
    project = {
        import_scan = false,
    },
})

local deleted_root = vim.fn.tempname()
vim.fn.mkdir(deleted_root, "p")
local deleted_chapter = deleted_root .. "/chapter.typ"
local deleted_main = deleted_root .. "/main.typ"
vim.fn.writefile({ "= Chapter" }, deleted_chapter)
vim.fn.writefile({ "= Main", '#include "chapter.typ"' }, deleted_main)

vim.cmd.edit(vim.fn.fnameescape(deleted_chapter))
local stale_project = typst.project.set_main(deleted_main)
vim.fn.delete(deleted_main)
local recovered_deleted = typst.project.get(0)
assert(
    recovered_deleted.main == util.normalize(deleted_chapter),
    "deleted explicit main should fall back to buffer"
)
assert(
    recovered_deleted.resolutions[vim.api.nvim_get_current_buf()].main_source
        == "current buffer",
    "deleted explicit main should record fallback source"
)
assert(vim.b.typst_main == nil, "deleted buffer-local main should be cleared")
assert(
    registry.all()[stale_project.key] == nil,
    "stale deleted-main project should be pruned after recovery"
)

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-lifecycle-output"),
    project = {
        import_scan = true,
        import_scan_max_files = 20,
        import_scan_max_depth = 1,
    },
})

local moved_root = vim.fn.tempname()
vim.fn.mkdir(moved_root, "p")
local moved_chapter = moved_root .. "/chapter.typ"
local moved_old_main = moved_root .. "/old-main.typ"
local moved_new_main = moved_root .. "/new-main.typ"
vim.fn.writefile({ "= Chapter" }, moved_chapter)
vim.fn.writefile({ "= Old Main", '#include "chapter.typ"' }, moved_old_main)
vim.fn.writefile({ "= New Main", '#include "chapter.typ"' }, moved_new_main)

vim.cmd.edit(vim.fn.fnameescape(moved_chapter))
local moved_stale_project = typst.project.set_main(moved_old_main)
vim.fn.delete(moved_old_main)
local recovered_moved = typst.project.get(0)
assert(
    recovered_moved.main == util.normalize(moved_new_main),
    "moved main should be recovered by import scan"
)
assert(
    recovered_moved.resolutions[vim.api.nvim_get_current_buf()].main_source
        == "import scan",
    "moved main recovery should record import scan as the source"
)
assert(
    vim.b.typst_main == nil,
    "stale moved buffer-local main should be cleared"
)
assert(
    registry.all()[moved_stale_project.key] == nil,
    "stale moved-main project should be pruned after recovery"
)

typst.reset()
typst.setup({
    root_markers = {},
    executable = helpers.fake_typst_sleep(root),
    output_dir = typst_test_cache_path("project-lifecycle-output"),
    compile = {
        deps = false,
    },
    project = {
        import_scan = false,
    },
})

local running_root = vim.fn.tempname()
vim.fn.mkdir(running_root, "p")
local running_chapter = running_root .. "/chapter.typ"
local running_main_a = running_root .. "/main-a.typ"
local running_main_b = running_root .. "/main-b.typ"
vim.fn.writefile({ "= Chapter" }, running_chapter)
vim.fn.writefile({ "= Main A", '#include "chapter.typ"' }, running_main_a)
vim.fn.writefile({ "= Main B", '#include "chapter.typ"' }, running_main_b)

vim.cmd.edit(vim.fn.fnameescape(running_chapter))
local running_project_a = typst.project.set_main(running_main_a)
local compile_handle = typst.compiler.compile({ notify = false })
assert(
    typst_test_compiler(running_project_a).process == compile_handle,
    "compile should be active before main changes"
)

local running_project_b = typst.project.set_main(running_main_b)
assert(
    running_project_b.key ~= running_project_a.key,
    "changing vim.b.typst_main should move to a new project"
)
assert(
    running_project_b.main == util.normalize(running_main_b),
    "new explicit main should be active after change"
)
assert(
    running_project_b.bufs[vim.api.nvim_get_current_buf()],
    "new project should own the buffer"
)
assert(
    vim.wait(10000, function()
        return registry.all()[running_project_a.key] == nil
            and typst_test_compiler(running_project_a).process == nil
            and typst_test_compiler(running_project_a).status == "idle"
            and compile_handle:is_closing()
    end, 20),
    "old compiling project should stop and prune after main change"
)

typst.reset()
typst.setup({
    root_markers = {},
    output_dir = typst_test_cache_path("project-lifecycle-output"),
    project = {
        import_scan = false,
    },
})

local event_root = vim.fn.tempname()
vim.fn.mkdir(event_root, "p")
local event_chapter = event_root .. "/chapter.typ"
local event_main_a = event_root .. "/main-a.typ"
local event_main_b = event_root .. "/main-b.typ"
vim.fn.writefile({ "= Chapter" }, event_chapter)
vim.fn.writefile({ "= Main A", '#include "chapter.typ"' }, event_main_a)
vim.fn.writefile({ "= Main B", '#include "chapter.typ"' }, event_main_b)

vim.cmd.edit(vim.fn.fnameescape(event_chapter))
local event_project_a = typst.project.set_main(event_main_a)
local seen_events = {}
local event_group = vim.api.nvim_create_augroup(
    "TypstProjectMainChangeEventSpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = { "TypstEventProjectDetach", "TypstEventProjectAttach" },
    callback = function(args)
        seen_events[#seen_events + 1] = {
            match = args.match,
            key = args.data and args.data.key,
        }
    end,
})

local event_project_b = typst.project.set_main(event_main_b)
assert(
    event_project_b.key ~= event_project_a.key,
    "set_main test should move the buffer to a new project"
)
assert(
    #seen_events == 2,
    "set_main should emit one detach and one attach event"
)
assert(
    seen_events[1].match == "TypstEventProjectDetach"
        and seen_events[1].key == event_project_a.key,
    "set_main should detach the old project first"
)
assert(
    seen_events[2].match == "TypstEventProjectAttach"
        and seen_events[2].key == event_project_b.key,
    "set_main should attach the new project second"
)

seen_events = {}
vim.b.typst_main = event_main_a
local lazy_project = typst.project.get(0)
assert(
    lazy_project.key == event_project_a.key,
    "lazy get should honor a changed buffer-local main"
)
assert(
    #seen_events == 2,
    "lazy project re-resolution should emit one detach and one attach event"
)
assert(
    seen_events[1].match == "TypstEventProjectDetach"
        and seen_events[1].key == event_project_b.key,
    "lazy re-resolution should detach the stale project first"
)
assert(
    seen_events[2].match == "TypstEventProjectAttach"
        and seen_events[2].key == event_project_a.key,
    "lazy re-resolution should attach the new project second"
)

vim.cmd("qa!")
