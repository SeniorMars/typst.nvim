local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local project_registry = require("typst.project.registry")
local project_store = require("typst.project.store")

typst.reset({ force = true })
typst.setup({
    root_markers = {},
    completion = {
        package_cache_prewarm = false,
    },
})

vim.cmd.enew()
vim.bo.filetype = ""

local no_project = typst.compiler.force_clear({ notify = false })
assert(
    type(no_project) == "table"
        and no_project.ok == false
        and no_project.reason == "no_project"
        and no_project.code == 1
        and no_project.stopped == false
        and no_project.stale == false,
    "force_clear no-project failure should preserve recovery result shape"
)

local unknown = typst.compiler.force_clear({
    key = "not-a-project-key",
    notify = false,
})
assert(
    type(unknown) == "table"
        and unknown.ok == false
        and unknown.reason == "unknown_project_key"
        and unknown.key == "not-a-project-key"
        and unknown.key_display == "not-a-project-key"
        and unknown.code == 1
        and unknown.stopped == false
        and unknown.stale == false,
    "force_clear unknown-key failure should preserve recovery result shape"
)

local collision_root = typst_test_cache_path("runtime-force-clear-collision")
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

local ambiguous = typst.compiler.force_clear({
    key = project_store.encode_key(literal_project.key),
    notify = false,
})
assert(
    type(ambiguous) == "table"
        and ambiguous.ok == false
        and ambiguous.reason == "ambiguous_project_key"
        and ambiguous.decoded_key == literal_project.key
        and ambiguous.code == 1
        and ambiguous.stopped == false
        and ambiguous.stale == false,
    "force_clear ambiguous-key failure should preserve recovery result shape"
)

project_store.remove(literal_project.key)
project_store.remove(decoded_project.key)
typst.reset({ force = true })

vim.cmd("qa!")
