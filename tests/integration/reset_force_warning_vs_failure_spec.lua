local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local project_store = require("typst.project.store")
local typst = require("typst")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
end

cleanup()

local stop_calls = 0
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("reset-force-warning-output"),
    preview = {
        open = function()
            return true
        end,
        stop = function()
            stop_calls = stop_calls + 1
            return {
                pending = true,
                on_finish_style = "colon",
                on_finish = function()
                    return nil
                end,
            }
        end,
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
project = require("typst.project.context").live(project) or project
assert(typst.viewer.preview() == true, "force reset fixture should preview")

local summary = typst.reset({ force = true, reason = "force-warning-spec" })
assert(summary.ok == true, "force reset local cleanup should succeed")
assert(summary.force == true, "summary should record force reset")
assert(
    summary.retained_projects == false,
    "force reset should not retain projects"
)
assert(summary.discarded == true, "force reset should report local discard")
assert(
    summary.backend_confirmed == false,
    "force reset should report unconfirmed backend stop"
)
assert(
    type(summary.warnings) == "table" and #summary.warnings >= 1,
    "force reset should expose unconfirmed stop warnings"
)
assert(stop_calls == 1, "force reset should attempt preview stop once")
assert(
    project_store.all()[project.key] == nil,
    "force reset should clear project store"
)
for _, blocker in ipairs(summary.blockers or {}) do
    assert(
        blocker.project_key ~= project.key,
        "force reset final snapshot should not retain project blockers"
    )
end

cleanup()
vim.cmd("qa!")
