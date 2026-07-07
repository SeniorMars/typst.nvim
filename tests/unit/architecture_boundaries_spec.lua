local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local cache_registry = require("typst.core.cache_registry")
local compiler_service = require("typst.project.services.compiler")
local core_result = require("typst.core.result")
local operation = require("typst.core.operation")
local core_windows = require("typst.core.windows")
local index_files = require("typst.project.index_files")
local output_ownership = require("typst.resources.outputs")
local project_attachments = require("typst.project.attachments")
local project_facade = require("typst.project")
local project_registry = require("typst.project.registry")
local project_resolver = require("typst.project.resolver")
local project_store = require("typst.project.store")
local resource_session = require("typst.resources.session")
local resource_manager = require("typst.runtime.resource_manager")
local resource_manager = require("typst.runtime.resource_manager")
local preview_service = require("typst.project.services.preview")
local compiler_api = require("typst.compiler")
local compiler_fanout = require("typst.compiler.fanout")
local compiler_typst_compile = require("typst.compiler.typst_compile")
local compiler_typst_process = require("typst.compiler.typst_process")
local compiler_typst_watcher = require("typst.compiler.watch.runner")
local compiler_watch_output = require("typst.compiler.output")
local edit_api = require("typst.edit.api")
local edit_treesitter = require("typst.core.treesitter")
local navigation_follow = require("typst.navigation.follow")
local navigation_follow_context = require("typst.navigation.follow_context")
local navigation_picker_backends = require("typst.navigation.picker_backends")
local navigation_toc = require("typst.navigation.toc")
local navigation_toc_collect = require("typst.navigation.toc_collect")
local preview_controller = require("typst.preview.controller")
local preview_results = require("typst.preview.results")
local preview_pending = require("typst.preview.pending")
local preview_state_machine = require("typst.preview.state_machine")
local preview_backend = require("typst.preview.backend")
local preview_source_sync = require("typst.preview.source_sync")
local preview_status = require("typst.preview.status")
local preview_capabilities = require("typst.preview.capabilities")
local preview_location = require("typst.preview.location")
local preview_delegated_runtime =
    require("typst.preview.backends.delegated_runtime")
local viewer_api = require("typst.viewer.api")
local viewer_generic = require("typst.viewer.generic")
local viewer_generic_helpers = require("typst.viewer.generic_helpers")

typst.reset({ force = true })
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("architecture-boundaries-output"),
})
local architecture_doc =
    table.concat(vim.fn.readfile(root .. "/docs/architecture.md"), "\n")
for _, phrase in ipairs({
    "Stability-First Target Layout",
    "Stable-Core Implementation Layout",
    "Post-Stable Target Boundaries",
    "Top-Level Mental Model",
    "What Not To Do",
    "Hard Ownership Boundaries",
    "project.store",
    "project.attachments",
    "project index modules",
    "core.windows",
    "runtime.resource_manager",
    "compiler.fanout",
    "Controller Extraction Guardrails",
    "typst.compiler decides stop/timeout semantics",
    "typst.preview.controller decides delegated preview stop semantics",
    "typst.viewer.api decides viewer/source-sync command semantics",
    "Do not extract broad controller modules before tests pin ownership",
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

local live_registry_allowlist = {
    ["lua/typst/project/registry.lua"] = true,
    ["lua/typst/project/store.lua"] = true,
    ["lua/typst/internal/debug.lua"] = true,
}
for _, file in ipairs(vim.fn.globpath(root .. "/lua", "**/*.lua", false, true)) do
    local rel = file:sub(#root + 2)
    if not live_registry_allowlist[rel] then
        local text = table.concat(vim.fn.readfile(file), "\n")
        assert(
            not text:find("%.live_all%(", 1)
                and not text:find("%.live_buffers%(", 1),
            ("feature modules should not use live project registry tables: %s"):format(
                rel
            )
        )
    end
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
assert(
    type(core_windows.for_buffer) == "function",
    "core.windows should expose shared visible-window lookup"
)
assert(
    type(cache_registry.forget_buffer) == "function"
        and type(cache_registry.detach_buffer) == "function"
        and type(cache_registry.forget_window) == "function",
    "cache registry should expose buffer/window lifecycle cleanup hooks"
)
assert(
    index_files == require("typst.project.index_files"),
    "project index file module should stay on its real path"
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
    project_store.project_for_buffer(bufnr) == project,
    "project.store should own buffer-to-project lookup"
)
assert(
    project_store.all()[project.key] == project,
    "project.store should expose live registry projects"
)
assert(
    project_facade.all()[project.key] ~= project
        and project_facade.all()[project.key].key == project.key,
    "typst.project facade should expose public project snapshots"
)
assert(
    type(project_attachments.install) == "function"
        and type(project_attachments.reapply_attached_buffers) == "function",
    "project.attachments should expose BufferAttachment lifecycle hooks"
)
assert(
    type(resource_manager.reset) == "function"
        and type(resource_manager.stop_before_prune) == "function"
        and type(resource_manager.has_active_resources) == "function"
        and type(resource_manager.snapshot) == "function"
        and type(resource_manager.stop_for_exit_all) == "function",
    "runtime.resource_manager should expose cleanup hooks"
)
assert(
    type(resource_manager.reset) == "function"
        and type(resource_manager.snapshot) == "function"
        and type(resource_manager.stop_live_resources) == "function"
        and type(resource_manager.in_reset) == "function",
    "runtime.resource_manager should expose the reset/resource ownership boundary"
)
local core_lifecycle = require("typst.core.lifecycle")
local saved_resource_manager = package.loaded["typst.runtime.resource_manager"]
local stop_before_prune_args = nil
package.loaded["typst.runtime.resource_manager"] = {
    stop_before_prune = function(...)
        stop_before_prune_args = { ... }
        return true
    end,
}
local prune_state = { key = "resource-manager-test" }
assert(
    core_lifecycle.stop_before_prune(prune_state, "log message", "prune reason")
        == true,
    "core.lifecycle should delegate stop-before-prune work to resource_manager"
)
package.loaded["typst.runtime.resource_manager"] = saved_resource_manager
assert(
    stop_before_prune_args
        and stop_before_prune_args[1] == prune_state
        and type(stop_before_prune_args[2]) == "table"
        and stop_before_prune_args[2].log_message == "log message"
        and stop_before_prune_args[2].reason == "prune reason",
    "core.lifecycle should pass structured prune options to resource_manager"
)
assert(
    type(compiler_fanout.compile_succeeded) == "function"
        and type(compiler_fanout.watch_cycle_failed) == "function",
    "compiler.fanout should expose compiler result consumer hooks"
)
assert(
    require("typst.compiler") == compiler_api,
    "typst.compiler should remain the compiler lifecycle entry point"
)
assert(
    require("typst.preview.controller") == preview_controller,
    "preview.controller should own preview lifecycle entrypoints"
)
assert(
    require("typst.integrations.typst_preview") == preview_controller,
    "typst-preview integration should remain a compatibility facade"
)
assert(
    require("typst.viewer.api") == viewer_api,
    "viewer.api should remain the viewer command entry point"
)
assert(
    type(compiler_api.compile) == "function"
        and type(compiler_api.stop_for_exit) == "function",
    "typst.compiler should own compile/watch/stop lifecycle entrypoints"
)
assert(
    type(preview_controller.open) == "function"
        and type(preview_controller.stop_for_exit) == "function",
    "preview.controller should expose preview liveness entrypoints"
)
assert(
    type(preview_results.stale_open) == "function"
        and type(preview_pending.cancel_current_open) == "function"
        and type(preview_state_machine.to_opening) == "function"
        and type(preview_backend.resolve) == "function",
    "preview controller helpers should expose result/pending/state/backend boundaries"
)
assert(
    type(preview_source_sync.forward) == "function"
        and type(preview_status.snapshot) == "function",
    "preview source-sync and status helpers should live under preview/"
)
assert(
    type(viewer_api.view) == "function"
        and type(viewer_api.preview_inverse) == "function",
    "viewer.api should own viewer/preview command orchestration"
)
assert(
    require("typst.compiler.typst_compile") == compiler_typst_compile,
    "compiler typst_compile path should remain available"
)
assert(
    require("typst.compiler.typst_process") == compiler_typst_process,
    "compiler typst_process path should remain available"
)
assert(
    require("typst.compiler.watch.runner") == compiler_typst_watcher,
    "compiler typst_watcher path should remain available"
)
assert(
    require("typst.compiler.output") == compiler_watch_output,
    "compiler output helper path should remain available"
)
assert(
    type(preview_delegated_runtime.command_available) == "function"
        and type(preview_state_machine.to_active_callback) == "function"
        and type(preview_capabilities.base) == "function"
        and type(preview_location.current_position) == "function",
    "preview helper modules should live under preview/"
)
assert(
    require("typst.viewer") == viewer_generic
        and require("typst.viewer.generic") == viewer_generic,
    "viewer generic backend should remain available at flat paths"
)
assert(
    require("typst.viewer.generic_helpers") == viewer_generic_helpers,
    "viewer generic helpers should remain available at flat paths"
)
assert(
    require("typst.edit.api") == edit_api
        and require("typst.core.treesitter") == edit_treesitter,
    "edit implementation should remain available at flat paths"
)
assert(
    require("typst.navigation.follow") == navigation_follow
        and require("typst.navigation.follow_context")
            == navigation_follow_context,
    "navigation follow implementation should remain available at flat paths"
)
assert(
    require("typst.navigation.toc") == navigation_toc
        and require("typst.navigation.toc_collect")
            == navigation_toc_collect,
    "navigation TOC implementation should remain available at flat paths"
)
assert(
    require("typst.navigation.picker_backends") == navigation_picker_backends,
    "navigation picker implementation should remain available at flat paths"
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
    "project.registry exact lookup should return raw keys"
)
assert(
    project_registry.get(project_registry.encode_key(literal_percent_key))
        == nil,
    "project.registry exact lookup should not decode fallback keys"
)
assert(
    project_registry.get_encoded(
        project_registry.encode_key(literal_percent_key)
    ) == literal_percent_project,
    "project.registry encoded lookup should resolve encoded literal-percent keys"
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
assert(
    resource_manager.has_active_resources(project) == false,
    "runtime.resource_manager should be the project liveness boundary"
)
local global_operation = operation.new("architecture-boundary-global")
local session_with_global = resource_session.snapshot(project)
assert(
    session_with_global.global_operations.active == 1,
    "resources.session should expose global operations"
)
assert(
    resource_session.global_snapshot().operations.active == 1,
    "resources.session should expose runtime-wide operation liveness"
)
assert(
    resource_session.has_active(project) == false,
    "global operations should not make an unrelated project active"
)
global_operation:finish({ code = 0, stdout = "", stderr = "" })
assert(
    resource_session.global_snapshot().operations.active == 0,
    "resources.session should clear global operation liveness after finish"
)

local prune_root =
    typst_test_cache_path("architecture-boundaries-output/prune-root")
local prune_project =
    project_store.create(prune_root, vim.fs.joinpath(prune_root, "main.typ"))
assert(
    next(prune_project.bufs or {}) == nil,
    "active-resource prune test should use an otherwise empty project"
)
local lease = assert(
    output_ownership.acquire(
        typst_test_cache_path("architecture-boundaries-output/main.pdf"),
        output_ownership.owner("unit-test", prune_project)
    )
)
assert(
    output_ownership.active_for_project(prune_project)[lease.key] == lease,
    "resources.outputs should expose project-owned leases"
)
assert(
    output_ownership.snapshot(prune_project)[1].path == lease.path,
    "resources.outputs should expose summary-safe lease snapshots"
)
assert(
    resource_session.has_active(prune_project) == true,
    "resources.session should treat active output leases as resources"
)
assert(
    resource_manager.has_active_resources(prune_project) == true,
    "runtime.resource_manager should retain projects with output leases"
)
assert(
    project_store.prune(prune_project, "active lease boundary test") == false,
    "project.store pruning should ask runtime.resource_manager before removal"
)
assert(
    output_ownership.release(lease) == true,
    "resources.outputs should release project-owned leases"
)
assert(
    resource_session.has_active(prune_project) == false,
    "resources.session should clear output lease activity after release"
)
assert(
    resource_manager.has_active_resources(prune_project) == false,
    "runtime.resource_manager should clear liveness after lease release"
)
assert(
    project_store.prune(prune_project, "released lease boundary test") == true,
    "project.store should prune an empty project once resource liveness clears"
)

preview_service.set(project, {
    active = true,
    active_backend = "callback",
})
assert(
    resource_session.has_active(project) == true,
    "resources.session should report active preview resources"
)
assert(
    resource_manager.has_active_resources(project) == true,
    "runtime.resource_manager should report active preview resources"
)

preview_service.set(project, {
    clear = { "active_backend" },
    active = false,
})
assert(
    resource_session.has_active(project) == false,
    "resources.session should clear active state after preview stops"
)
assert(
    resource_manager.has_active_resources(project) == false,
    "runtime.resource_manager should clear preview liveness after stop"
)

typst.reset({ force = true })
vim.cmd("qa!")
