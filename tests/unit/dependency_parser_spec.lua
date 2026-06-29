local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local dependencies = require("typst.compiler.dependencies")
local util = require("typst.core.util")

local deps_path = typst_test_cache_path("dependency-parser/deps.json")
vim.fn.mkdir(vim.fs.dirname(deps_path), "p")

vim.fn.writefile({
    vim.json.encode({
        inputs = {
            "tests/fixtures/basic/main.typ",
            "tests/fixtures/basic/chapter.typ",
            "tests/fixtures/basic/chapter.typ",
        },
        outputs = {
            "/tmp/output.pdf",
        },
        future = {
            url = "https://example.com/not-a-dependency.typ",
            label = "notes.typ",
        },
    }),
}, deps_path)

local parsed = dependencies.read(deps_path, root)
assert(
    parsed and #parsed == 2,
    "dependency parser should read and deduplicate explicit inputs only"
)
assert(
    parsed[1] == util.resolve_path("tests/fixtures/basic/main.typ", root),
    "first dependency should be canonicalized"
)
assert(
    parsed[2] == util.resolve_path("tests/fixtures/basic/chapter.typ", root),
    "second dependency should be canonicalized"
)

vim.fn.writefile({
    vim.json.encode({
        outputs = {
            "tests/fixtures/basic/appendix.typ",
        },
        arbitrary = {
            "tests/fixtures/basic/chapter.typ",
        },
    }),
}, deps_path)

local no_inputs = dependencies.read(deps_path, root)
assert(
    no_inputs and #no_inputs == 0,
    "dependency parser should fail closed when inputs are absent"
)

vim.fn.writefile({
    vim.json.encode({
        inputs = "tests/fixtures/basic/main.typ",
    }),
}, deps_path)

assert(
    dependencies.read(deps_path, root, { quiet = true }) == nil,
    "invalid dependency input schema should fail"
)

local watcher = {}
for _ = 1, 3 do
    assert(
        dependencies.next_poll_delay(watcher, false) == 250,
        "dependency watcher should poll quickly after startup"
    )
end
assert(
    dependencies.next_poll_delay(watcher, false) == 1000,
    "dependency watcher should back off after unchanged polls"
)
for _ = 1, 8 do
    dependencies.next_poll_delay(watcher, false)
end
assert(
    dependencies.next_poll_delay(watcher, false) == 2000,
    "dependency watcher should use slow polling after sustained inactivity"
)
assert(
    dependencies.next_poll_delay(watcher, true) == 250,
    "dependency watcher should return to fast polling after changes"
)

local fake_timer = {
    closed = false,
    close_count = 0,
    stop_count = 0,
}
function fake_timer:is_closing()
    return self.closed
end
function fake_timer:stop()
    self.stop_count = self.stop_count + 1
end
function fake_timer:close()
    self.close_count = self.close_count + 1
    self.closed = true
end

local poll_watcher = { deps_timer = fake_timer }
dependencies.stop_poll(poll_watcher)
dependencies.stop_poll(poll_watcher)
assert(poll_watcher.deps_timer == nil, "dependency timer should be cleared")
assert(fake_timer.stop_count == 1, "dependency timer should stop once")
assert(fake_timer.close_count == 1, "dependency timer should close once")

vim.cmd("qa!")
