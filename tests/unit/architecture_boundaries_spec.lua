local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local compiler_service = require("typst.project.services.compiler")
local core_result = require("typst.core.result")
local output_ownership = require("typst.resources.outputs")
local project_facade = require("typst.project")
local project_registry = require("typst.project.registry")
local project_resolver = require("typst.project.resolver")
local resource_session = require("typst.resources.session")
local preview_service = require("typst.project.services.preview")

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("architecture-boundaries-output"),
})

local architecture_doc =
    table.concat(vim.fn.readfile(root .. "/docs/architecture.md"), "\n")
for _, phrase in ipairs({
    "Workflow-First Target Layout",
    "Top-Level Mental Model",
    "What Not To Do",
    "Hard Ownership Boundaries",
    "resources.cleanup",
    "compiler.controller",
    "preview.controller",
    "viewer.controller",
    "diagnostics.publisher",
    "Command-to-module intent",
}) do
    assert(
        architecture_doc:find(phrase, 1, true),
        ("architecture docs should preserve workflow boundary phrase: %s"):format(
            phrase
        )
    )
end

assert(
    core_result.is_confirmed_stopped({ stopped = true }) == true,
    "core.result should classify confirmed stopped results"
)
assert(
    core_result.is_confirmed_stopped({ idle = true, stopped = false }) == false,
    "core.result should reject contradictory idle/stopped=false results"
)
assert(
    core_result.is_unconfirmed_stop({ idle = true, stopped = false }) == true,
    "core.result should treat contradictory idle/stopped=false results as unconfirmed"
)
assert(
    core_result.idle({ stopped = false }).stopped == true,
    "core.result idle constructor should not return stopped=false"
)
assert(
    core_result.is_unconfirmed_stop({ reason = "timeout", stopped = false })
        == true,
    "core.result should classify timeout as unconfirmed stop"
)
assert(
    core_result.is_unconfirmed_stop({
        ok = false,
        code = 1,
        stopped = false,
        reason = "compile_failed",
    }) == false,
    "ordinary compiler failures should not be treated as unconfirmed stops"
)
assert(
    core_result.stop_allows_restart({ ok = false, stopped = false }) == false,
    "core.result should block restart after failed stop"
)

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local bufnr = vim.api.nvim_get_current_buf()
local candidate = project_resolver.resolve_candidate(bufnr)
assert(candidate.main == main, "project.resolver should resolve main path")

local project = project_facade.resolve(bufnr)
local idle_exit = require("typst.compiler.typst").stop_for_exit(project)
assert(
    idle_exit.idle == true
        and idle_exit.stopped == true
        and core_result.is_confirmed_stopped(idle_exit),
    "built-in idle stop_for_exit should be a confirmed stopped result"
)
assert(
    (compiler_service.get(project) or {}).status == "idle",
    "built-in idle stop_for_exit should leave compiler state idle"
)
assert(
    project_registry.project_for_buffer(bufnr) == project,
    "project.registry should own buffer-to-project lookup"
)
assert(
    project_facade.all()[project.key] == project,
    "typst.project facade should expose registry projects"
)
for _, raw_key in ipairs({
    "/tmp/a%2Fb main.typ",
    "C:%5CUsers%5CTypst Project\\main.typ",
    "root with spaces\nmain with %25 percent",
}) do
    local encoded = project_registry.encode_key(raw_key)
    assert(
        project_registry.decode_key(encoded) == raw_key,
        "project.registry should round-trip encoded command keys"
    )
    assert(
        not encoded:find("[\n\r%s]", 1),
        "project.registry encoded keys should be command-safe"
    )
end
local literal_percent_key = "root%2Fmain"
local decoded_slash_key = "root/main"
local literal_percent_project = { key = literal_percent_key }
local decoded_slash_project = { key = decoded_slash_key }
project_registry.set(literal_percent_key, literal_percent_project)
project_registry.set(decoded_slash_key, decoded_slash_project)
assert(
    project_registry.get(literal_percent_key) == literal_percent_project,
    "project.registry should prefer exact raw keys before decoding"
)
assert(
    project_registry.get(project_registry.encode_key(literal_percent_key))
        == literal_percent_project,
    "project.registry should resolve encoded literal-percent keys"
)
local ambiguous_project, ambiguous_reason =
    project_registry.resolve_key(project_registry.encode_key(decoded_slash_key))
assert(
    ambiguous_project == nil and ambiguous_reason == "ambiguous_project_key",
    "project.registry raw-compatible lookup should fail closed for raw/encoded key collisions"
)
assert(
    project_registry.get_encoded(project_registry.encode_key(decoded_slash_key))
        == decoded_slash_project,
    "project.registry encoded command lookup should resolve encoded slash keys without percent collision"
)
project_registry.remove(literal_percent_key)
project_registry.remove(decoded_slash_key)
assert(
    resource_session.has_active(project) == false,
    "resources.session should report no active resources initially"
)

local lease = assert(
    output_ownership.acquire(
        typst_test_cache_path("architecture-boundaries-output/main.pdf"),
        output_ownership.owner("unit-test", project)
    )
)
assert(
    output_ownership.active_for_project(project)[lease.key] == lease,
    "resources.outputs should expose project-owned leases"
)
assert(
    output_ownership.snapshot(project)[1].path == lease.path,
    "resources.outputs should expose summary-safe lease snapshots"
)
assert(
    resource_session.has_active(project) == true,
    "resources.session should treat active output leases as resources"
)
assert(
    output_ownership.release(lease) == true,
    "resources.outputs should release project-owned leases"
)
assert(
    resource_session.has_active(project) == false,
    "resources.session should clear output lease activity after release"
)

preview_service.set(project, {
    active = true,
    active_backend = "callback",
})
assert(
    resource_session.has_active(project) == true,
    "resources.session should report active preview resources"
)

preview_service.set(project, {
    clear = { "active_backend" },
    active = false,
})
assert(
    resource_session.has_active(project) == false,
    "resources.session should clear active state after preview stops"
)

typst.reset({ force = true })
vim.cmd("qa!")
