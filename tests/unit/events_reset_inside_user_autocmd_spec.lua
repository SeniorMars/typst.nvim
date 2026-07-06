local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local events = require("typst.core.events")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    completion = {
        package_cache_prewarm = false,
    },
})

local ran_deferred = false
local autocmd_seen = false
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstEventQuit",
    once = true,
    callback = function()
        autocmd_seen = true
        assert(events.in_user_event(), "autocmd should run during event emit")
        assert(
            events.defer_state_change("unit-reset", function()
                ran_deferred = true
            end),
            "state change should defer during event emit"
        )
        typst.reset({ force = true })
    end,
})

events.emit_global("TypstEventQuit", { projects = 0 })

assert(autocmd_seen, "event autocmd should run")
assert(
    ran_deferred == false,
    "reset inside event should drop deferred state changes"
)
assert(
    events.in_user_event() == false,
    "reset inside event should leave no active event depth"
)
local state = events._state_for_tests()
assert(state.emitting_depth == 0, "event emitting depth should be reset")
assert(state.deferred_count == 0, "deferred queue should be reset")
assert(state.draining_deferred == false, "deferred drain flag should be reset")

vim.cmd("qa!")
