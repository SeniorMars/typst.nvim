local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local hooks = require("typst.runtime.hooks")

local function autocmd_count(group)
    local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = group })
    if not ok then
        return 0
    end
    return #autocmds
end

typst.reset({ force = true })
local init_pre_events = {}
local init_events = {}
local config_changed_events = {}
local event_order = {}
local prewarm_calls = 0
local original_packages = package.loaded["typst.completion.packages"]
package.loaded["typst.completion.packages"] = {
    prewarm = function(opts)
        assert(
            opts and opts.schedule == true,
            "setup prewarm should remain scheduled"
        )
        prewarm_calls = prewarm_calls + 1
    end,
}
local init_group = vim.api.nvim_create_augroup("TypstRuntimeResetHooksSpec", {
    clear = true,
})
vim.api.nvim_create_autocmd("User", {
    group = init_group,
    pattern = "TypstEventInitPre",
    callback = function(args)
        event_order[#event_order + 1] = args.match
        init_pre_events[#init_pre_events + 1] = args.data or {}
    end,
})
vim.api.nvim_create_autocmd("User", {
    group = init_group,
    pattern = "TypstEventInitPost",
    callback = function(args)
        event_order[#event_order + 1] = args.match
        init_events[#init_events + 1] = args.data or {}
    end,
})
vim.api.nvim_create_autocmd("User", {
    group = init_group,
    pattern = "TypstEventConfigChanged",
    callback = function(args)
        event_order[#event_order + 1] = args.match
        config_changed_events[#config_changed_events + 1] = args.data or {}
    end,
})
typst.setup({
    completion = {
        package_cache_prewarm = true,
    },
    preview = {
        follow_buffer = true,
    },
})
local follow_count_after_first =
    autocmd_count("typst_nvim_preview_follow_buffer")
typst.setup({
    completion = {
        package_cache_prewarm = true,
    },
    preview = {
        follow_buffer = true,
    },
})

assert(
    init_events[1] and init_events[1].first_setup == true,
    "first setup should identify first_setup events"
)
assert(
    init_pre_events[1] and init_pre_events[1].first_setup == true,
    "first setup should identify first_setup pre-events"
)
assert(
    init_events[2] and init_events[2].reconfigure == true,
    "second setup should identify reconfigure events"
)
assert(
    init_pre_events[2] and init_pre_events[2].reconfigure == true,
    "second setup should identify reconfigure pre-events"
)
assert(
    #config_changed_events == 1 and config_changed_events[1].reconfigure == true,
    "reconfigure should emit a dedicated config-changed event"
)
assert(
    table.concat(event_order, ",")
        == "TypstEventInitPre,TypstEventInitPost,TypstEventInitPre,TypstEventConfigChanged,TypstEventInitPost",
    "setup events should keep documented first-setup and reconfigure order"
)
assert(
    prewarm_calls == 1,
    "reconfigure should not schedule duplicate package prewarm probes"
)

assert(
    autocmd_count("typst_nvim_preview_follow_buffer") > 0,
    "setup should install follow-buffer autocmds"
)
assert(
    autocmd_count("typst_nvim_preview_follow_buffer")
        == follow_count_after_first,
    "reconfigure should replace rather than stack follow-buffer autocmds"
)

local hook_names = {}
for _, hook in ipairs(hooks.status()) do
    hook_names[hook.name] = true
end
assert(
    hook_names["core.events"],
    "runtime hooks should expose event-queue reset ownership"
)
assert(
    hook_names["preview.follow_buffer"],
    "runtime hooks should expose follow-buffer reset ownership"
)
assert(
    hook_names["project.attachments"],
    "runtime hooks should expose attachment reset ownership"
)

local result = typst.reset({ force = true })
pcall(vim.api.nvim_del_augroup_by_id, init_group)
package.loaded["typst.completion.packages"] = original_packages
assert(
    autocmd_count("typst_nvim_preview_follow_buffer") == 0,
    "runtime reset should remove follow-buffer autocmds"
)
assert(
    type(result) == "table"
        and type(result.runtime_hooks) == "table"
        and result.runtime_hooks["preview.follow_buffer"].ok == true
        and result.runtime_hooks["preview.follow_buffer"].status == "reset",
    "runtime reset should report reset hook summary"
)

local events = require("typst.core.events")
local deferred_ran = false
local reset_group = vim.api.nvim_create_augroup("TypstRuntimeEventResetSpec", {
    clear = true,
})
vim.api.nvim_create_autocmd("User", {
    group = reset_group,
    pattern = "TypstRuntimeEventResetSpec",
    callback = function()
        events.defer_state_change("reset-spec", function()
            deferred_ran = true
        end)
        events.reset()
    end,
})
events.emit_global("TypstRuntimeEventResetSpec", {})
pcall(vim.api.nvim_del_augroup_by_id, reset_group)
assert(not deferred_ran, "event reset should discard deferred mutations")
assert(not events.in_user_event(), "event reset should leave event depth idle")

local api_exports = require("typst.api.exports")
local runtime_setup = require("typst.runtime.setup")
local api1 = {}
api_exports.install(api1, function() end)
runtime_setup.setup(api1, function() end, {})
assert(
    type(api1.compiler) == "table" and type(api1.compiler.watch) == "function",
    "runtime setup should install methods on the first API facade"
)
runtime_setup.reset({ force = true })
local api2 = {}
api_exports.install(api2, function() end)
runtime_setup.setup(api2, function() end, {})
assert(
    type(api2.compiler) == "table" and type(api2.compiler.watch) == "function",
    "runtime setup should install methods on a fresh API facade after reset"
)
runtime_setup.reset({ force = true })

local unsafe_configure = runtime_setup.configure({})
assert(
    unsafe_configure
        and unsafe_configure.ok == false
        and unsafe_configure.reason == "runtime_not_setup",
    "runtime.configure should reject calls before one-time setup"
)
assert(
    runtime_setup.is_setup() == false,
    "rejected runtime.configure should not mark runtime setup complete"
)

local configure_events = {}
local configure_group = vim.api.nvim_create_augroup(
    "TypstRuntimeConfigureEventSpec",
    { clear = true }
)
vim.api.nvim_create_autocmd("User", {
    group = configure_group,
    pattern = "TypstEventConfigChanged",
    callback = function(args)
        configure_events[#configure_events + 1] = args.data or {}
    end,
})
local api3 = {}
api_exports.install(api3, function() end)
runtime_setup.setup(api3, function() end, {})
local configure_result = runtime_setup.configure({})
pcall(vim.api.nvim_del_augroup_by_id, configure_group)
assert(
    configure_result and configure_result.ok == true,
    "runtime.configure should succeed after setup_once"
)
assert(
    #configure_events == 1 and configure_events[1].reconfigure == true,
    "runtime.configure should emit TypstEventConfigChanged after setup"
)
runtime_setup.reset({ force = true })
