local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local opened = nil
local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("preview-fallback-output"),
    viewer = {
        open = function(path)
            opened = path
        end,
    },
    preview = {
        fallback = "view",
    },
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before preview fallback test")
    done = true
end)

assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish"
)

local preview_event = nil
vim.api.nvim_create_autocmd("User", {
    pattern = "TypstPreviewOpened",
    callback = function(args)
        preview_event = args.data
    end,
})

typst.viewer.preview()
assert(
    opened == typst_test_compiler(project).output,
    "preview fallback did not use viewer output"
)
assert(
    preview_event,
    "TypstPreviewOpened event was not emitted for viewer fallback"
)
assert(
    preview_event.key == project.key,
    "preview fallback event had wrong project key"
)
assert(
    preview_event.backend == "viewer",
    "preview fallback event had wrong backend"
)
assert(
    preview_event.output == typst_test_compiler(project).output,
    "preview fallback event had wrong output"
)
assert(
    typst_test_preview(project).last_backend == "viewer",
    "project should record viewer fallback preview backend"
)
assert(
    preview_event.preview_backend == "viewer",
    "preview fallback event should expose recorded backend"
)

vim.cmd("qa!")
