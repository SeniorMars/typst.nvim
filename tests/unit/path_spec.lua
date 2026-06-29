local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_registry = require("typst.project")
local project_services = require("typst.project.services")
local util = require("typst.core.util")

assert(
    util.path_identity("c:\\Users\\Charlie\\Project\\main.typ")
        == "c:/users/charlie/project/main.typ",
    "Windows drive paths should use stable casing and forward separators"
)

assert(
    util.path_key("c:\\Users\\Charlie\\Project\\main.typ")
        == "c:/users/charlie/project/main.typ",
    "path keys should preserve raw Windows identity before platform-local normalization"
)

assert(
    util.same_path(
        "c:\\Users\\Charlie\\Project\\main.typ",
        "C:/users/charlie/project/main.typ"
    ),
    "Windows drive paths should compare case-insensitively"
)

assert(
    util.path_within(
        "c:\\Users\\Charlie\\Project\\chapters\\one.typ",
        "C:/users/charlie/project"
    ),
    "Windows drive paths should tolerate mixed separators in containment checks"
)

assert(
    not util.path_within(
        "c:\\Users\\Charlie\\Projector\\one.typ",
        "C:/users/charlie/project"
    ),
    "Windows containment checks should require a path boundary"
)

assert(
    util.path_within(
        "\\\\Server\\Share\\Project\\main.typ",
        "//server/share/project"
    ),
    "UNC paths should compare case-insensitively with normalized separators"
)

if not util.is_windows() then
    assert(
        not util.same_path("/tmp/Typst/Main.typ", "/tmp/typst/main.typ"),
        "POSIX path comparison should remain case-sensitive"
    )
    assert(
        util.resolve_path("C:/Users/Charlie/Project/main.typ", root)
            == "C:/Users/Charlie/Project/main.typ",
        "foreign Windows drive paths should not be resolved under the POSIX root"
    )
    assert(
        util.resolve_path("c:\\Users\\Charlie\\Project\\main.typ", root)
            == "C:/Users/Charlie/Project/main.typ",
        "foreign Windows drive paths should normalize separators without joining the root"
    )
    assert(
        util.resolve_path("\\\\Server\\Share\\Project\\main.typ", root)
            == "//Server/Share/Project/main.typ",
        "foreign UNC paths should not be resolved under the POSIX root"
    )
end

local fake_project = {
    main = "C:/Users/Charlie/Project/main.typ",
    bufs = {},
}
project_services.ensure(fake_project)
local raw_main = "c:\\users\\charlie\\project\\main.typ"
local raw_chapter = "c:\\users\\charlie\\project\\chapter.typ"
project_registry.update_dependencies(
    fake_project,
    { raw_main, raw_chapter },
    { source = "compiler" }
)
local graph = project_services.graph(fake_project)

assert(
    graph.dependency_sources[util.normalize(raw_main)] == "explicit",
    "dependency source classification should recognize Windows-equivalent main paths"
)
assert(
    graph.file_sources[util.normalize(raw_main)] == "explicit",
    "rebuilt file sources should preserve explicit classification for Windows-equivalent main paths"
)
assert(
    graph.dependency_sources[util.normalize(raw_chapter)] == "compiler",
    "non-main dependencies should keep the compiler source"
)

project_registry.update_dependencies(
    fake_project,
    { raw_main, raw_chapter },
    { source = "heuristic" }
)
graph = project_services.graph(fake_project)

assert(
    graph.dependency_sources[util.normalize(raw_chapter)] == "compiler",
    "heuristic refreshes should not demote compiler-discovered dependencies"
)
assert(
    graph.file_sources[util.normalize(raw_chapter)] == "compiler",
    "rebuilt file sources should keep the strongest dependency source"
)

project_registry.update_dependencies(
    fake_project,
    { raw_main },
    { source = "heuristic" }
)
graph = project_services.graph(fake_project)

assert(
    graph.dependencies[util.normalize(raw_chapter)] == nil,
    "dependency refreshes should still drop omitted stale dependencies"
)
assert(
    graph.dependency_sources[util.normalize(raw_chapter)] == nil,
    "dependency refreshes should drop sources for omitted stale dependencies"
)
assert(
    graph.files[util.normalize(raw_chapter)] == nil,
    "file index should drop omitted stale dependencies"
)

vim.cmd("qa!")
