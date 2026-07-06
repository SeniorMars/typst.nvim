local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local lock_helper = require("tests.helpers.output_locks")
local outputs = require("typst.resources.outputs")
local reports = require("typst.ui.reports")
local typst = require("typst")

typst.reset({ force = true })
outputs.reset()
lock_helper.reset_lock_dir()

local fixture_root = lock_helper.base_dir("output-lock-release-report")
local main = lock_helper.path(fixture_root, "main.typ")
vim.fn.writefile({ "= Main" }, main)

typst.setup({
    root = fixture_root,
    completion = {
        package_cache_prewarm = false,
    },
})

vim.cmd.edit(main)
vim.bo.filetype = "typst"
local project = typst.project.attach(0)
assert(
    project and project.main == main,
    "fixture should attach a Typst project"
)

local failed_output = lock_helper.path(fixture_root, "release-failure.pdf")
local lease = assert(
    outputs.acquire(failed_output, outputs.owner("release-report", project))
)
vim.fn.writefile({
    vim.json.encode({
        pid = 999999999,
        path = failed_output,
        owner = { kind = "foreign-owner" },
    }),
}, outputs._owner_path(failed_output))

assert(
    outputs.release(lease),
    "release should drop the in-process lease even when file lock cleanup fails"
)

local _, info_lines = typst.ui.info({ echo = false })
local info_text = table.concat(info_lines, "\n")
assert(
    info_text:find("last output lock release failure:", 1, true),
    "TypstInfo report should show the last output lock release failure"
)
assert(
    info_text:find("release%-failure%.pdf"),
    "TypstInfo report should include the failed output path"
)
assert(
    info_text:find("context:%s+release"),
    "TypstInfo report should include the release context"
)
assert(
    info_text:find("error:%s+foreign_lock_owner"),
    "TypstInfo report should include the release failure reason"
)

local unrelated_project = {
    key = project.key .. ":unrelated",
    root = project.root,
    main = project.main,
}
assert(
    outputs.last_release_failure(unrelated_project) == nil,
    "release failure reports should remain scoped to the owning project"
)

local clean_lines = reports.clean_output_locks_lines({
    path = failed_output,
    force = true,
})
local clean_text = table.concat(clean_lines, "\n")
assert(
    clean_text:find("removed=1", 1, true),
    "forced filtered lock cleanup should remove the leftover failed lock"
)
assert(
    clean_text:find("removed%s+"),
    "lock cleanup report should list the removed lock"
)
assert(
    vim.fn.isdirectory(lease.lock_path) == 0,
    "forced filtered cleanup should remove the failed release lock directory"
)

vim.cmd("qa!")
