local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local log = require("typst.core.log")
local project_services = require("typst.project.services")
local project_store = require("typst.project.store")
local typst = require("typst")
local util = require("typst.core.util")

local function cleanup()
    pcall(function()
        typst.reset({ force = true })
    end)
    pcall(function()
        vim.cmd("silent! %bwipeout!")
    end)
    log.clear()
end

local function has_dependency(project, path)
    local graph = project_services.graph(project)
    return graph ~= nil and graph.dependencies[util.normalize(path)] == true
end

local function saw_log(message)
    for _, entry in ipairs(log.entries()) do
        if entry.message == message then
            return true
        end
    end
    return false
end

local function run_schema_case(schema, assert_case)
    cleanup()
    vim.env.TYPST_NVIM_FAKE_DEPS_SCHEMA = schema
    typst.setup({
        root = root .. "/tests/fixtures/basic",
        executable = helpers.python_command(
            root .. "/tests/fixtures/fake-typst-deps-schema.py"
        ),
        output_dir = typst_test_cache_path("deps-schema-output-" .. schema),
        compile = {
            deps = true,
        },
    })
    local main = root .. "/tests/fixtures/basic/main.typ"
    vim.cmd.edit(main)
    local project_snapshot = typst.project.set_main(main)
    local project =
        assert(project_store.get(project_snapshot.key), "live project")
    ---@type any
    local result = nil
    typst.compiler.compile({}, function(done)
        result = done
    end)
    assert(
        vim.wait(10000, function()
            return result ~= nil
        end, 20),
        ("compile did not finish for dependency schema %s"):format(schema)
    )
    assert(result.code == 0, "fake Typst compile should succeed")
    assert(
        result.deps_path and vim.fn.filereadable(result.deps_path) == 0,
        "dependency JSON should be consumed and removed"
    )
    assert_case(project)
end

local old_schema = vim.env.TYPST_NVIM_FAKE_DEPS_SCHEMA
local ok, err = xpcall(function()
    run_schema_case("valid", function(project)
        assert(
            has_dependency(project, root .. "/tests/fixtures/basic/main.typ"),
            "valid deps should include main"
        )
        assert(
            has_dependency(project, root .. "/tests/fixtures/basic/chapter.typ"),
            "valid deps should include chapter"
        )
        assert(
            has_dependency(
                project,
                root .. "/tests/fixtures/basic/assets/image.svg"
            ),
            "valid deps should include image"
        )
        assert(
            not has_dependency(
                project,
                root .. "/tests/fixtures/basic/ignored.typ"
            ),
            "parser should ignore future non-input fields"
        )
    end)
    run_schema_case("missing-inputs", function(project)
        assert(
            not has_dependency(
                project,
                root .. "/tests/fixtures/basic/chapter.typ"
            ),
            "missing inputs should not infer dependencies from other fields"
        )
        assert(
            not saw_log("Typst dependency JSON has an unsupported schema"),
            "missing inputs should be treated as an empty supported schema"
        )
    end)
    run_schema_case("invalid-inputs", function(project)
        assert(
            not has_dependency(
                project,
                root .. "/tests/fixtures/basic/chapter.typ"
            ),
            "invalid input schema should not update dependencies"
        )
        assert(
            saw_log("Typst dependency JSON has an unsupported schema"),
            "invalid input schema should be logged clearly"
        )
    end)
    run_schema_case("malformed", function(project)
        assert(
            not has_dependency(
                project,
                root .. "/tests/fixtures/basic/chapter.typ"
            ),
            "malformed dependency JSON should not update dependencies"
        )
        assert(
            saw_log("failed to parse Typst dependency JSON"),
            "malformed dependency JSON should be logged clearly"
        )
    end)
end, debug.traceback)

vim.env.TYPST_NVIM_FAKE_DEPS_SCHEMA = old_schema
cleanup()

if not ok then
    error(err)
end

vim.cmd("qa!")
