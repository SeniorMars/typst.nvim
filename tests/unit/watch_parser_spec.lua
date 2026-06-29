local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local parser = require("typst.compiler.watch_parser")

local cases = {
    {
        line = "[12:34:56] compiling ...",
        event = "start",
    },
    {
        line = "compiling ...",
        event = "start",
    },
    {
        line = "typst watch: compiling ...",
        event = "start",
    },
    {
        line = "[12:34:57] compiled successfully",
        event = "success",
    },
    {
        line = "compiled in 12ms",
        event = "success",
    },
    {
        line = "successfully compiled document",
        event = "success",
    },
    {
        line = "[12:34:58] compiled with errors",
        event = "error",
    },
    {
        line = "compilation failed",
        event = "error",
    },
    {
        line = "\27[32mcompiled successfully\27[0m",
        event = "success",
    },
    {
        line = '{"event":"compile-start","status":"running"}',
        event = "start",
    },
    {
        line = '{"event":"compile-success","status":"success"}',
        event = "success",
    },
    {
        line = '{"event":"compile-error","status":"error"}',
        event = "error",
    },
}

for _, case in ipairs(cases) do
    local parsed = parser.parse(case.line)
    assert(parsed, ("expected parsed event for %q"):format(case.line))
    assert(
        parsed.event == case.event,
        ("expected %s for %q, got %s"):format(
            case.event,
            case.line,
            parsed.event
        )
    )
end

local unknown = parser.parse("typst watch: compiling finished somehow")
assert(
    unknown and unknown.event == "unknown",
    "status-like unknown output failed"
)

assert(
    parser.parse("main.typ:1:1: error: nope") == nil,
    "diagnostic line parsed"
)

local structured_only_start = parser.parse(
    '{"event":"compile-start","status":"running"}',
    { structured_only = true }
)
assert(
    structured_only_start and structured_only_start.event == "start",
    "structured-only watch parser should accept JSON-line events"
)

local explicit_structured_start =
    parser.parse('{"event":"start","status":"running"}', {
        structured_only = true,
    })
assert(
    explicit_structured_start and explicit_structured_start.event == "start",
    "structured-only watch parser should accept explicit lifecycle JSON events"
)

local explicit_structured_success =
    parser.parse('{"event":"finished","status":"ok"}', {
        structured_only = true,
    })
assert(
    explicit_structured_success
        and explicit_structured_success.event == "success",
    "structured-only watch parser should accept explicit lifecycle success JSON events"
)

local structured_only_human =
    parser.parse("[12:34:56] compiling ...", { structured_only = true })
assert(
    structured_only_human
        and structured_only_human.event == "unknown"
        and structured_only_human.reason == "non_structured_status",
    "structured-only watch parser should flag human status output"
)

local compiler_command = require("typst.compiler.command")
local project_services = require("typst.project.services")
local project = {
    root = root,
    main = root .. "/tests/fixtures/basic/index-main.typ",
    services = project_services.new_state(),
}
project_services.set_compiler(project, {
    output = typst_test_cache_path("watch-parser-output.pdf"),
})
local watch_args = compiler_command.build_args("watch", project, {
    compile = {
        extra_args = {},
        watch_output = "structured",
        watch_structured_args = { "--diagnostic-format", "json" },
        deps = false,
        open = false,
    },
})
assert(
    vim.deep_equal(vim.list_slice(watch_args, 4, 5), {
        "--diagnostic-format",
        "json",
    }),
    "structured watch arguments should be appended for watch commands"
)

local human_args = compiler_command.build_args("watch", project, {
    compile = {
        extra_args = {},
        watch_output = "human",
        watch_structured_args = { "--diagnostic-format", "json" },
        deps = false,
        open = false,
    },
})
for _, arg in ipairs(human_args) do
    assert(
        arg ~= "--diagnostic-format",
        "human watch output should not append structured watch arguments"
    )
end

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
                ("%s expected %s for %q"):format(fixture, expected, text)
            )
        end
    end
    assert(checked > 0, fixture .. " should contain expected events")
end

vim.cmd("qa!")
