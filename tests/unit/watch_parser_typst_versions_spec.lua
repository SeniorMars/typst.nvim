local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local parser = require("typst.compiler.watch_parser")

local required_fixtures = {
    "typst-0.11.txt",
    "typst-0.13.txt",
    "typst-0.14.txt",
    "typst-0.15.txt",
    "structured-json.txt",
}

for _, name in ipairs(required_fixtures) do
    local path = root .. "/tests/fixtures/watch-output/" .. name
    assert(vim.fn.filereadable(path) == 1, "missing watch fixture " .. name)
end

for _, fixture in
    ipairs(
        vim.fn.glob(root .. "/tests/fixtures/watch-output/*.txt", false, true)
    )
do
    local checked = 0
    for _, line in ipairs(vim.fn.readfile(fixture)) do
        local expected, text = line:match("^([^|]+)|(.+)$")
        if expected then
            checked = checked + 1
            local parsed = parser.parse(text)
            assert(
                parsed and parsed.event == expected,
                ("%s expected %s for %q, got %s"):format(
                    fixture,
                    expected,
                    text,
                    parsed and parsed.event or "nil"
                )
            )
        end
    end
    assert(checked > 0, fixture .. " should contain expected events")
end

local unknown =
    assert(parser.parse("typst watch: compilation entered a new phase"))
assert(unknown.event == "unknown", "unknown status-like output should surface")

vim.cmd("qa!")
