local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local operations = require("typst.project.services.operations")
local output_ownership = require("typst.resources.outputs")
local project_store = require("typst.project.store")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("status-output"),
})
local detached = typst.ui.status()
assert(
    not detached.attached,
    "new buffer should not have an attached Typst project"
)
assert(typst.ui.statusline() == "", "detached statusline should be empty")

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
local live_project = assert(project_store.get(project.key), "live project")

local snapshot = typst.ui.status()
assert(snapshot.attached, "Typst status should report attached project")
assert(
    snapshot.key == project.key,
    "Typst status returned the wrong project key"
)
assert(snapshot.status == "idle", "initial Typst status should be idle")
assert(
    snapshot.main_name == "main.typ",
    "Typst status should include main file name"
)
assert(
    snapshot.output_name == "main.pdf",
    "Typst status should include output file name"
)
assert(
    snapshot.cwd == root,
    "Typst status should include project cwd before a compile"
)
assert(
    snapshot.root_source == "config.root",
    "Typst status should include the root decision source"
)
assert(
    snapshot.main_source == "buffer variable vim.b.typst_main",
    "Typst status should include the main decision source"
)
assert(
    snapshot.diagnostics == 0,
    "Typst status should start without diagnostics"
)
assert(
    snapshot.tinymist_lsp_backend == "nvim_lsp"
        and snapshot.tinymist_lsp_attached == false,
    "Typst status should report Tinymist Neovim LSP absence"
)
assert(
    snapshot.compiler_diagnostics == "fallback_active",
    "Typst status should explain active fallback diagnostics when Tinymist is absent"
)
typst.index.collect({ project = project })
typst.index.collect({ project = project })
snapshot = typst.ui.status()
assert(
    snapshot.index_stats.collect_misses > 0
        and snapshot.index_stats.collect_hits > 0,
    "Typst status should expose project index cache hits and misses"
)
local _, status_lines = typst.ui.status_report({ echo = false })
local saw_index_stats = false
for _, line in ipairs(status_lines) do
    if line:find("index cache: collect", 1, true) then
        saw_index_stats = true
        break
    end
end
assert(saw_index_stats, "status_report should include index cache statistics")

local retained = assert(operations.begin(live_project, "status-retained"))
operations.retain(live_project, retained, {
    ok = false,
    reason = "status_fixture",
})
local blocker_lease = assert(
    output_ownership.acquire(
        typst_test_cache_path("status-output/blocker.pdf"),
        output_ownership.owner("status-blocker", live_project)
    )
)
snapshot = typst.ui.status()
assert(
    (snapshot.blocker_count or 0) >= 2,
    "Typst status should expose resource blocker count"
)
local blocker_kinds = {}
for _, blocker in ipairs(snapshot.blockers or {}) do
    blocker_kinds[blocker.kind] = true
end
assert(
    blocker_kinds.operation_retained and blocker_kinds.output_lease,
    "Typst status should expose retained-operation and output-lease blockers"
)
_, status_lines = typst.ui.status_report({ echo = false })
local status_text = table.concat(status_lines, "\n")
assert(
    status_text:find("blockers:", 1, true)
        and status_text:find("operation_retained", 1, true)
        and status_text:find("output_lease", 1, true),
    "status_report should list resource blockers"
)
output_ownership.release(blocker_lease)
operations.finish(live_project, retained, {
    ok = false,
    reason = "status_fixture_cleared",
})
require("typst.core.telemetry").time("status.spec", function() end)
local telemetry_snapshot = typst.ui.status({ telemetry = true })
assert(
    type(telemetry_snapshot.telemetry) == "table",
    "status({ telemetry = true }) should include telemetry samples"
)
assert(
    type(telemetry_snapshot.telemetry_report) == "table",
    "status({ telemetry = true }) should include telemetry report lines"
)
local telemetry_report_snapshot, telemetry_lines =
    typst.ui.status_report({ telemetry = true, echo = false })
assert(
    type(telemetry_report_snapshot.telemetry) == "table",
    "status_report({ telemetry = true }) should return telemetry samples"
)
assert(
    vim.tbl_contains(telemetry_lines, "  telemetry:"),
    "status_report({ telemetry = true }) should include telemetry lines"
)
assert(
    typst.ui.statusline() == "Typst:idle main.typ",
    "initial statusline was wrong"
)

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before status test")
    done = true
end)
assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish"
)

snapshot = typst.ui.status()
assert(
    snapshot.status == "success",
    "status should update after successful compile"
)
assert(
    vim.deep_equal(snapshot.command, typst_test_compiler(project).last_command),
    "status should expose last compile command"
)
assert(snapshot.cwd == root, "status should expose last compile cwd")
assert(
    typst.ui.statusline({ main = false }) == "Typst:success",
    "statusline options were not honored"
)

vim.cmd("qa!")
