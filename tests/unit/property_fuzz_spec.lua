local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local diagnostics_parser = require("typst.diagnostics.parser")
local watch_parser = require("typst.compiler.watch.parser")
local dependencies = require("typst.compiler.dependencies")
local bibliography_parser = require("typst.bibliography.parser")
local manifest = require("typst.package.manifest")
local metadata_artifacts = require("typst.metadata.artifacts")
local edit_ts = require("typst.core.treesitter")

typst.reset()
typst.setup({
    root = root,
    output_dir = typst_test_cache_path("property-fuzz-output"),
})
local workdir = typst_test_cache_path("property-fuzz")
vim.fn.mkdir(workdir, "p")

local rng_state = 0x5eed123
local function rand(max)
    rng_state = (rng_state * 1103515245 + 12345) % 0x80000000
    return (rng_state % max) + 1
end

local atoms = {
    "a",
    "b",
    "z",
    "_",
    "-",
    "0",
    " ",
    "=",
    "{",
    "}",
    ":",
    ",",
    "\\",
    "\195\169",
    "\206\177",
    "\228\184\173",
    "\240\159\152\128",
    "\204\129",
}

local function random_text(max_len)
    local out = {}
    for _ = 1, rand(max_len) do
        out[#out + 1] = atoms[rand(#atoms)]
    end
    return table.concat(out)
end

local function assert_no_throw(name, fn)
    local ok, err = pcall(fn)
    assert(ok, ("%s should not throw: %s"):format(name, tostring(err)))
end

local source_lines = {
    "alpha " .. "\195\169" .. " beta",
    "emoji " .. "\240\159\152\128" .. " text",
    "combining e" .. "\204\129" .. " accent",
    "tab\tcolumn",
}
local main_path = workdir .. "/main.typ"
vim.fn.writefile(source_lines, main_path)
local project = {
    root = workdir,
    main = main_path,
}

for index = 1, 80 do
    assert_no_throw("diagnostic parser fuzz", function()
        local level = ({ "error", "warning", "info", "hint" })[rand(4)]
        local row = rand(#source_lines)
        local col = #source_lines[row] + rand(16)
        local text = ("main.typ:%d:%d: %s: %s"):format(
            row,
            col,
            level,
            random_text(24)
        )
        local parsed = diagnostics_parser.parse(project, text)
        for bufnr, diagnostics in pairs(parsed) do
            for _, diagnostic in ipairs(diagnostics) do
                assert(diagnostic.lnum >= 0, "diagnostic row should be clamped")
                local path = vim.api.nvim_buf_get_name(bufnr)
                local line = path == main_path
                        and source_lines[diagnostic.lnum + 1]
                    or ""
                assert(
                    diagnostic.col >= 0 and diagnostic.col <= #line,
                    "diagnostic byte column should be clamped to the line"
                )
            end
        end
    end)
end

local structured_events = {
    start = '{"event":"compile-start","status":"running"}',
    success = '{"event":"compile-success","status":"success"}',
    error = '{"event":"compile-error","status":"error"}',
}
for event, line in pairs(structured_events) do
    local parsed = watch_parser.parse(line, { structured_only = true })
    assert(
        parsed and parsed.event == event and parsed.profile == "structured-json",
        "structured watch fuzz fixture should parse " .. event
    )
end
for _ = 1, 120 do
    assert_no_throw("watch parser fuzz", function()
        watch_parser.parse(random_text(48))
    end)
end

local deps_path = workdir .. "/deps.json"
vim.fn.writefile({
    vim.json.encode({
        inputs = { "main.typ", "./sub.typ", "./sub.typ", 42, "" },
        unrelated = { "not-a-dependency.typ" },
    }),
}, deps_path)
local deps = dependencies.read(deps_path, workdir, { quiet = true })
assert(
    deps and #deps == 2,
    "dependency parser should validate and dedupe inputs"
)

vim.fn.writefile(
    { vim.json.encode({ dependencies = { "old-shape.typ" } }) },
    deps_path
)
local ignored = dependencies.read(deps_path, workdir, { quiet = true })
assert(
    ignored and #ignored == 0,
    "dependency parser should ignore unknown schema fields"
)

vim.fn.writefile({ vim.json.encode({ inputs = "main.typ" }) }, deps_path)
assert(
    dependencies.read(deps_path, workdir, { quiet = true }) == nil,
    "dependency parser should reject unsupported input schemas"
)

for index = 1, 60 do
    assert_no_throw("BibTeX parser fuzz", function()
        local entries = bibliography_parser.parse_bibtex_lines({
            ("@article{k%d,"):format(index),
            ("title = {%s},"):format(random_text(20):gsub("[{}]", "")),
            ("year = {%d}"):format(2000 + rand(40)),
            "}",
            random_text(32),
        })
        for _, entry in ipairs(entries) do
            assert(
                entry.key and entry.key ~= "",
                "BibTeX entry key should exist"
            )
            assert(entry.lnum >= 1, "BibTeX line number should be one-based")
        end
    end)
    assert_no_throw("Hayagriva parser fuzz", function()
        local entries = bibliography_parser.parse_hayagriva_lines({
            ("key%d:"):format(index),
            "  type: Article",
            "  title: " .. random_text(20):gsub("[:#]", ""),
            "  author:",
            "    - name: Fuzz",
        })
        for _, entry in ipairs(entries) do
            assert(entry.key and entry.key ~= "", "YAML entry key should exist")
            assert(entry.lnum >= 1, "YAML line number should be one-based")
        end
    end)
end

for index = 1, 40 do
    assert_no_throw("package manifest parser fuzz", function()
        local path = ("%s/typst-%d.toml"):format(workdir, index)
        vim.fn.writefile({
            "# random comments should be ignored",
            "[package]",
            ('name = "fuzz-%d"'):format(index),
            ('version = "0.%d.0"'):format(rand(9)),
            ('description = "%s"'):format(random_text(20):gsub('["\\]', "")),
            "[template]",
            'path = "template/main.typ"',
        }, path)
        local parsed = manifest.read(path)
        assert(parsed.name == ("fuzz-%d"):format(index), "manifest name parsed")
    end)
end

for _ = 1, 80 do
    assert_no_throw("MessagePack metadata fuzz", function()
        local bytes = {}
        for _ = 1, rand(32) do
            bytes[#bytes + 1] = string.char(rand(255) - 1)
        end
        local decoded_ok, decoded = pcall(vim.mpack.decode, table.concat(bytes))
        if decoded_ok then
            local accepted = pcall(
                metadata_artifacts.expect_artifact,
                decoded,
                "fuzz",
                "0.0.0",
                7,
                3
            )
            if accepted then
                assert(
                    decoded[1] == 7 and decoded[2] == "0.0.0" and #decoded == 3,
                    "accepted MessagePack artifact must match the declared schema"
                )
            end
        end
    end)
end

assert(
    not pcall(metadata_artifacts.expect_artifact, {}, "fuzz", "0.0.0", 7, 3),
    "metadata artifacts should fail closed when required fields are missing"
)

local function has_error_node(node)
    if node:type() == "ERROR" then
        return true
    end
    for child in node:iter_children() do
        if has_error_node(child) then
            return true
        end
    end
    return false
end

local function run_edit_properties()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "typst"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "*alpha*" })
    local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "typst")
    if not ok_parser or not parser then
        return
    end

    for _, word in ipairs({
        "alpha",
        "beta_1",
        "\206\177\206\178",
        "e\204\129",
    }) do
        local original = "*" .. word .. "*"
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { original })
        local original_col = assert(original:find(word, 1, true)) - 1
        vim.api.nvim_win_set_cursor(0, { 1, original_col })
        local first = typst.edit.toggle_strong({ notify = false })
        assert(first.ok, first.message or "toggle_strong should apply")
        local transformed = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
        local transformed_col = assert(transformed:find(word, 1, true)) - 1
        vim.api.nvim_win_set_cursor(0, { 1, transformed_col })
        local second = typst.edit.toggle_strong({ notify = false })
        assert(second.ok, second.message or "toggle_strong should revert")
        local current = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
        assert(current == original, "toggle_strong twice should restore bytes")
        local tree = edit_ts.root(bufnr)
        assert(tree and not has_error_node(tree), "edited Typst should reparse")
    end
end

assert_no_throw("editing transform property", run_edit_properties)

vim.cmd("qa!")
