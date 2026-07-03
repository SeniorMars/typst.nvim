local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local output_ownership = require("typst.resources.outputs")
local operations = require("typst.project.services.operations")
local project_store = require("typst.project.store")
local typst = require("typst")
typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("info-output"),
})

local main = root .. "/tests/fixtures/basic/main.typ"
vim.cmd.edit(main)
local project = typst.project.set_main(main)
local live_project = assert(project_store.get(project.key), "live project")

local done = false
typst.compiler.compile({}, function(result)
    assert(result.code == 0, "compile failed before info test")
    done = true
end)

assert(
    vim.wait(10000, function()
        return done
    end, 20),
    "Typst compile did not finish"
)

local entries = typst.ui.log()
local started
for _, entry in ipairs(entries) do
    if entry.message == "compile started" then
        started = entry
        break
    end
end

assert(started, "compile start was not logged")
assert(
    started.fields.cwd == root,
    "compile log should include working directory"
)
assert(
    vim.deep_equal(
        started.fields.command,
        typst_test_compiler(project).last_command
    ),
    "compile log should include exact command"
)
assert(
    typst_test_compiler(project).last_cwd == root,
    "project should remember the last process working directory"
)

local captured = {}
local original_echo = vim.api.nvim_echo
vim.api.nvim_echo = function(chunks)
    for _, chunk in ipairs(chunks) do
        captured[#captured + 1] = chunk[1]
    end
end

local ok, err = pcall(function()
    typst.ui.info()
end)

vim.api.nvim_echo = original_echo
assert(ok, err)

local text = table.concat(captured, "\n")
assert(
    text:find("cwd:%s+" .. vim.pesc(root)),
    "TypstInfo should show the process cwd"
)
assert(
    text:find("provider:%s+typst"),
    "TypstInfo should show the compiler provider"
)
assert(
    text:find("command:%s+typst compile"),
    "TypstInfo should show the last command"
)
assert(
    text:find(vim.pesc(typst_test_compiler(project).output)),
    "TypstInfo should show the output path"
)
assert(
    text:find("root source:%s+config%.root"),
    "TypstInfo should show the root decision"
)
assert(
    text:find("main source:%s+buffer variable vim%.b%.typst_main"),
    "TypstInfo should show the main decision"
)
assert(
    text:find("tinymist nvim%-lsp:%s+auto not attached"),
    "TypstInfo should show project Tinymist Neovim LSP absence"
)
assert(
    text:find("compiler diagnostics:%s+fallback active"),
    "TypstInfo should explain active fallback diagnostics when Tinymist is absent"
)

local lease = assert(
    output_ownership.acquire(
        typst_test_cache_path("info-output/held.pdf"),
        output_ownership.owner("info-test", live_project)
    )
)
local record = assert(operations.begin(live_project, "export"))
operations.retain(live_project, record, { orphaned = true, reason = "test" })

captured = {}
vim.api.nvim_echo = function(chunks)
    for _, chunk in ipairs(chunks) do
        captured[#captured + 1] = chunk[1]
    end
end

ok, err = pcall(function()
    typst.ui.info()
end)

vim.api.nvim_echo = original_echo
assert(ok, err)

text = table.concat(captured, "\n")
assert(
    text:find("active output leases:%s+1"),
    "TypstInfo should show active output leases"
)
assert(
    text:find("retained orphan operations:%s+1"),
    "TypstInfo should show retained orphan operations"
)

output_ownership.release(lease)
operations.clear(live_project, record)

local release_failure_lease = assert(
    output_ownership.acquire(
        typst_test_cache_path("info-output/release-failure.pdf"),
        output_ownership.owner("info-release-failure", live_project)
    )
)
vim.fn.writefile({
    vim.json.encode({
        pid = 999999999,
        path = release_failure_lease.path,
        owner = { kind = "foreign-owner" },
    }),
}, output_ownership._owner_path(release_failure_lease.path))
assert(
    output_ownership.release(release_failure_lease),
    "info fixture should release in-process lease despite lock cleanup failure"
)

captured = {}
vim.api.nvim_echo = function(chunks)
    for _, chunk in ipairs(chunks) do
        captured[#captured + 1] = chunk[1]
    end
end

ok, err = pcall(function()
    typst.ui.info()
end)

vim.api.nvim_echo = original_echo
assert(ok, err)

text = table.concat(captured, "\n")
assert(
    text:find("last output lock release failure:", 1, true),
    "TypstInfo should show the last output lock release failure"
)
assert(
    text:find("error:%s+foreign_lock_owner"),
    "TypstInfo should show the output lock release failure reason"
)
vim.fn.delete(release_failure_lease.lock_path, "rf")

vim.cmd("qa!")
