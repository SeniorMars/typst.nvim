local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local debug_tools = require("typst.internal.debug")
local project_store = require("typst.project.store")
local typst = require("typst")

local fixture_dir = typst_test_cache_path("stable-core-invariants")
vim.fn.mkdir(fixture_dir, "p")

local first_main = fixture_dir .. "/first.typ"
local second_main = fixture_dir .. "/second.typ"
vim.fn.writefile({ "= First" }, first_main)
vim.fn.writefile({ "= Second" }, second_main)

typst.reset()
typst.setup({
    root = fixture_dir,
    output_dir = typst_test_cache_path("stable-core-output"),
})
vim.cmd.edit(first_main)
local bufnr = vim.api.nvim_get_current_buf()
local first = assert(typst.project.set_main(first_main))
local second = assert(typst.project.set_main(second_main))
assert(first.key ~= second.key, "fixture should create two project identities")

local live_first = project_store.get(first.key)
local live_second = project_store.get(second.key)
assert(
    not live_first or not (live_first.bufs or {})[bufnr],
    "buffer must not remain attached to the old project after reassignment"
)
assert(
    live_second and (live_second.bufs or {})[bufnr],
    "buffer must belong to the reassigned project"
)
assert(
    project_store.project_for_buffer(bufnr) == live_second,
    "buffer registry must point at the current project"
)

local finish_open = nil
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("stable-core-preview-output"),
    preview = {
        open = function()
            local handle = {
                pending = true,
                on_finish_style = "colon",
            }
            function handle:on_finish(callback)
                finish_open = callback
                return self
            end
            function handle:cancel()
                return true, { ok = true, stopped = true }
            end
            return handle
        end,
    },
})
local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
local pending = typst.viewer.preview({ notify = false })
assert(
    pending and pending.pending == true,
    "preview open fixture should return a pending handle"
)
local preview_state = typst_test_preview(project)
assert(
    preview_state.opening == true and preview_state.active == false,
    "pending preview open must use opening state, not active state"
)
local stopped = typst.viewer.preview_stop({ notify = false, reason = "test" })
assert(
    type(stopped) == "table" and stopped.stopped == true,
    "stopping a pending preview open should confirm cancellation"
)
assert(finish_open)({ ok = true, opened = true })
preview_state = typst_test_preview(project)
assert(
    preview_state.active == false and preview_state.opening == false,
    "late preview open completion after stop must not reactivate preview"
)

local invariants = debug_tools.check_invariants()
assert(invariants.ok == true, "stable-core invariant checker should pass")

vim.cmd("qa!")
