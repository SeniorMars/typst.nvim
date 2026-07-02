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
        init_pre_events[#init_pre_events + 1] = args.data or {}
    end,
})
vim.api.nvim_create_autocmd("User", {
    group = init_group,
    pattern = "TypstEventInitPost",
    callback = function(args)
        init_events[#init_events + 1] = args.data or {}
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
