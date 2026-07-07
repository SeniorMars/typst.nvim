local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local events = require("typst.core.events")
local typst = require("typst")

local function setup_case()
    typst.reset({ force = true })
    typst.setup({
        completion = {
            package_cache_prewarm = false,
        },
    })
    events._reset_for_tests()
end

setup_case()

local project = {
    key = "events-reset-reentrancy",
    root = root,
    main = root .. "/tests/fixtures/basic/main.typ",
}

local primary_seen = false
local alias_seen = false
local dropped_deferred = false
local reset_group = vim.api.nvim_create_augroup(
    "TypstEventsResetReentrancySpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = reset_group,
    pattern = "TypstCompileStarted",
    once = true,
    callback = function()
        primary_seen = true
        assert(
            events.in_user_event(),
            "primary event should run in event scope"
        )
        assert(
            events.defer_state_change("dropped-reset-change", function()
                dropped_deferred = true
            end),
            "state changes should defer before reset"
        )
        typst.reset({ force = true })
    end,
})
vim.api.nvim_create_autocmd("User", {
    group = reset_group,
    pattern = { "TypstEventCompileStarted", "TypstEventCompiling" },
    callback = function()
        alias_seen = true
    end,
})

events.emit("TypstCompileStarted", project, { status = "compiling" })
assert(primary_seen == true, "primary event should be emitted")
assert(alias_seen == false, "reset during primary event should skip aliases")
assert(
    dropped_deferred == false,
    "reset during event should drop previously deferred state changes"
)
local state = events._state_for_tests()
assert(state.emitting_depth == 0, "reset path should leave no event depth")
assert(state.deferred_count == 0, "reset path should clear deferred changes")
assert(state.draining_deferred == false, "reset path should clear drain state")

setup_case()

local order = {}
local nested_group = vim.api.nvim_create_augroup(
    "TypstEventsNestedReentrancySpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = nested_group,
    pattern = "TypstEventInitPre",
    once = true,
    callback = function()
        order[#order + 1] = "outer"
        assert(
            events.defer_state_change("outer-deferred", function()
                order[#order + 1] = "outer-deferred"
            end),
            "outer event should defer state change"
        )
        events.emit_global("TypstEventConfigChanged", { nested = true })
        order[#order + 1] = "outer-after-inner"
    end,
})
vim.api.nvim_create_autocmd("User", {
    group = nested_group,
    pattern = "TypstEventConfigChanged",
    once = true,
    callback = function()
        order[#order + 1] = "inner"
        assert(
            events.defer_state_change("inner-deferred", function()
                order[#order + 1] = "inner-deferred"
            end),
            "inner event should defer state change"
        )
    end,
})

events.emit_global("TypstEventInitPre", { nested = false })
assert(
    table.concat(order, ",")
        == "outer,inner,outer-after-inner,outer-deferred,inner-deferred",
    "nested emits should drain deferred changes only after the outer event"
)
state = events._state_for_tests()
assert(state.emitting_depth == 0, "nested emits should restore depth")
assert(state.deferred_count == 0, "nested emits should drain deferred changes")
assert(state.draining_deferred == false, "nested emits should finish draining")

setup_case()

local good_deferred_ran = false
local bad_group = vim.api.nvim_create_augroup(
    "TypstEventsDeferredFailureSpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = bad_group,
    pattern = "TypstEventInitPost",
    once = true,
    callback = function()
        assert(
            events.defer_state_change("bad-deferred", function()
                error("forced deferred failure")
            end),
            "bad deferred callback should queue"
        )
        assert(
            events.defer_state_change("good-deferred", function()
                good_deferred_ran = true
            end),
            "good deferred callback should queue"
        )
    end,
})

events.emit_global("TypstEventInitPost", {})
assert(
    good_deferred_ran == true,
    "deferred drain should continue after a failing callback"
)
state = events._state_for_tests()
assert(state.emitting_depth == 0, "deferred failure should restore depth")
assert(state.deferred_count == 0, "deferred failure should clear queue")
assert(
    state.draining_deferred == false,
    "deferred failure should clear drain flag"
)

setup_case()

local reset_drain_order = {}
local reset_drain_group = vim.api.nvim_create_augroup(
    "TypstEventsDeferredResetSpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = reset_drain_group,
    pattern = "TypstEventConfigChanged",
    once = true,
    callback = function()
        assert(
            events.defer_state_change("reset-during-drain", function()
                reset_drain_order[#reset_drain_order + 1] = "reset"
                events.reset()
            end),
            "reset deferred callback should queue"
        )
        assert(
            events.defer_state_change("dropped-after-reset", function()
                reset_drain_order[#reset_drain_order + 1] = "dropped"
            end),
            "post-reset deferred callback should queue before reset happens"
        )
    end,
})

events.emit_global("TypstEventConfigChanged", {})
assert(
    table.concat(reset_drain_order, ",") == "reset",
    "reset during deferred drain should drop the rest of the pending batch"
)
state = events._state_for_tests()
assert(state.emitting_depth == 0, "deferred reset should restore depth")
assert(state.deferred_count == 0, "deferred reset should clear queue")
assert(
    state.draining_deferred == false,
    "deferred reset should clear drain flag"
)

vim.cmd("qa!")
