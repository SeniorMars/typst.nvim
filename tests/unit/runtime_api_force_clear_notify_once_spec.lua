local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local buffer = require("typst.core.buffer")
local dispatch = require("typst.api.runtime_dispatch")
local project_registry = require("typst.project.registry")
local project_store = require("typst.project.store")
local spec = require("typst.api.runtime_spec")
local typst = require("typst")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    completion = {
        package_cache_prewarm = false,
    },
})

local notifications = {}
local api = {}
dispatch.install(api, spec.endpoints, {
    normalize_bufnr = buffer.normalize_bufnr,
    notify = function(message, level)
        notifications[#notifications + 1] = {
            message = message,
            level = level,
        }
    end,
})

api.compiler.force_clear({ key = "not-a-project-key" })
assert(#notifications == 1, "unknown-key force_clear should notify once")
assert(
    notifications[1].level == vim.log.levels.ERROR,
    "unknown-key force_clear should notify at error level"
)

api.compiler.force_clear({ key = "not-a-project-key", notify = false })
assert(#notifications == 1, "notify=false should suppress force_clear notify")

vim.cmd.enew()
vim.bo.filetype = ""
api.compiler.force_clear({})
assert(#notifications == 2, "no-project force_clear should notify once")
assert(
    notifications[2].level == vim.log.levels.WARN,
    "no-project force_clear should notify at warn level"
)

local collision_root = typst_test_cache_path("runtime-force-clear-notify")
vim.fn.delete(collision_root, "rf")
vim.fn.mkdir(collision_root, "p")
local literal_project = {
    key = "literal/project",
    root = collision_root,
    main = collision_root .. "/literal.typ",
    bufs = {},
    services = {},
}
local decoded_project = {
    key = project_store.encode_key(literal_project.key),
    root = collision_root,
    main = collision_root .. "/decoded.typ",
    bufs = {},
    services = {},
}
project_registry.set(literal_project.key, literal_project)
project_registry.set(decoded_project.key, decoded_project)

api.compiler.force_clear({ key = project_store.encode_key(literal_project.key) })
assert(#notifications == 3, "ambiguous-key force_clear should notify once")
assert(
    notifications[3].level == vim.log.levels.ERROR,
    "ambiguous-key force_clear should notify at error level"
)

project_store.remove(literal_project.key)
project_store.remove(decoded_project.key)
typst.reset({ force = true })

vim.cmd("qa!")
