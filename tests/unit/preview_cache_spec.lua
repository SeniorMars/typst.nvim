local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
typst.reset()

local provider_calls = 0
local opened = nil
local export_provider = function(_project, opts, callback)
    provider_calls = provider_calls + 1
    vim.fn.writefile(
        { ("<svg>%d</svg>"):format(provider_calls) },
        opts.output_path
    )
    local result = {
        ok = true,
        path = opts.output_path,
        artifacts = {
            {
                path = opts.output_path,
                format = opts.format or "svg",
            },
        },
    }
    if callback then
        callback(result)
    end
    return result
end

typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-cache-compile-output"),
    viewer = {
        open = function(path)
            opened = path
            return true
        end,
    },
    preview = {
        native = "viewer",
        cache = {
            enabled = true,
            max_entries = 1,
            max_bytes = 0,
            ttl_ms = 0,
        },
        export = {
            mode = "provider",
            provider = export_provider,
            output_format = "svg",
            output_name = "preview-old",
            output_dir = typst_test_cache_path("preview-cache-exports"),
        },
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local old_path = typst.viewer.preview({ mode = "document" })
assert(old_path == opened, "preview should open old provider output")
assert(vim.fn.filereadable(old_path) == 1, "old preview artifact should exist")

require("typst.config").unsafe_get().preview.export.output_name = "preview-new"
local new_path = typst.viewer.preview({
    mode = "document",
    restart = true,
})
assert(new_path == opened, "preview should open new provider output")
assert(vim.fn.filereadable(new_path) == 1, "new preview artifact should exist")
assert(
    vim.fn.filereadable(old_path) == 0,
    "preview cache retention should delete stale preview artifact"
)

local status = typst.viewer.preview_status({ echo = false, notify = false })
assert(status.cache.count == 1, "preview status should expose cache count")
assert(
    status.lines and table.concat(status.lines, "\n"):find("cache: 1 entries"),
    "preview status lines should include cache summary"
)

vim.cmd("TypstPreviewStatus!")
assert(
    vim.bo.filetype == "typstpreviewstatus",
    "TypstPreviewStatus! should open a preview status buffer"
)

vim.cmd.edit(main)
vim.cmd("TypstCleanPreview")
assert(
    vim.fn.filereadable(new_path) == 0,
    "TypstCleanPreview should remove preview-owned artifacts"
)
assert(
    typst.viewer.preview_status({ echo = false, notify = false }).cache.count
        == 0,
    "preview clean should remove preview artifact registry entries"
)

vim.cmd("qa!")
