local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_services = require("typst.project.services")
local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("invalidation-output"),
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
local live_project = assert(require("typst.project.store").get(project.key))

local seen = {}
local unsubscribe = typst.invalidation.subscribe(project, "*", function(event)
    seen[#seen + 1] = event
end)
local baseline_generation = typst.invalidation.generation(project)
local baseline_buffer_changed =
    typst.invalidation.generation(project, "buffer_changed")
typst.index.mark_dirty(project, "manual")
assert(
    typst.invalidation.generation(project) == baseline_generation + 1,
    "manual dirty should increment invalidation generation"
)
assert(
    seen[1].event == "manual",
    "manual dirty should emit a manual invalidation event"
)
assert(
    seen[1].index_generation == project_services.index(live_project).generation,
    "event should include index generation"
)

typst.project.invalidate(project, "config_changed", { source = "test" })
assert(
    typst.invalidation.generation(project) == baseline_generation + 2,
    "explicit invalidation should increment generation"
)
assert(
    seen[2].event == "config_changed",
    "explicit invalidation should preserve event name"
)
assert(
    seen[2].source == "test",
    "explicit invalidation should preserve payload fields"
)

unsubscribe()
typst.index.mark_dirty(project, "buffer changed")
assert(
    #seen == 2,
    "unsubscribed invalidation listener should not receive later events"
)
assert(
    typst.invalidation.generation(project, "buffer_changed")
        == baseline_buffer_changed + 1,
    "event-specific invalidation counter should be tracked"
)

local snapshot = typst.project.invalidation_snapshot(project)
assert(
    snapshot.generation == baseline_generation + 3,
    "snapshot should include total generation"
)
assert(
    snapshot.counters.buffer_changed == baseline_buffer_changed + 1,
    "snapshot should include event counters"
)

local text_events = {}
local unsubscribe_text = typst.invalidation.subscribe(
    project,
    "buffer_changed",
    function(event)
        text_events[#text_events + 1] = event
    end
)
local before_text_generation =
    typst.invalidation.generation(project, "buffer_changed")
local current_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_exec_autocmds("TextChanged", { buffer = current_buf })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = current_buf })
assert(
    typst.invalidation.generation(project, "buffer_changed")
        == before_text_generation + 1,
    "duplicate TextChanged events with the same changedtick should invalidate once"
)
assert(
    #text_events == 1,
    "duplicate TextChanged events with the same changedtick should emit once"
)
unsubscribe_text()

local uv = vim.uv or vim.loop
if uv and type(uv.new_fs_event) == "function" then
    local watch_dir = typst_test_cache_path("invalidation-watch")
    vim.fn.mkdir(watch_dir, "p")
    local watch_main = watch_dir .. "/main.typ"
    local watch_lib = watch_dir .. "/lib.typ"
    vim.fn.writefile({ '#include "lib.typ"' }, watch_main)
    vim.fn.writefile({ "= Old <sec:event-old>" }, watch_lib)
    vim.cmd.edit(vim.fn.fnameescape(watch_main))
    vim.bo.filetype = "typst"
    local watch_project = assert(typst.project.set_main(watch_main))
    local watch_events = {}
    typst.invalidation.subscribe(
        watch_project,
        "disk_file_changed",
        function(event)
            watch_events[#watch_events + 1] = event
        end
    )
    local collected = typst.index.collect({ project = watch_project })
    assert(
        #collected.labels > 0,
        "event-driven invalidation fixture should index imported labels"
    )

    vim.fn.writefile({ "= New <sec:event-new>" }, watch_lib)
    assert(
        vim.wait(1000, function()
            return #watch_events > 0
        end, 10),
        "fs_event should mark project index dirty after watched file changes"
    )
end

vim.cmd("qa!")
