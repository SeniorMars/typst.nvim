local ctx = require("tests.helpers.compiler_commands").setup()
local root = ctx.root
local typst = ctx.typst
local project = ctx.project
local main_bufnr = ctx.main_bufnr

typst_test_compiler(project).status = "error"

vim.api.nvim_set_current_buf(main_bufnr)
local selected_done = false
local selected_code = nil
local selected_fragment = nil
local selected = typst.compiler.compile_selected(
    { notify = false, line1 = 1, line2 = 1, range = 1 },
    function(result, fragment)
        selected_code = result.code
        selected_fragment = fragment
        selected_done = true
    end
)
assert(
    selected.ok == true,
    "compile_selected should start selected-fragment compilation"
)
assert(
    selected.template == "markup",
    "compile_selected should use the default fragment template"
)
assert(
    selected.range[1] == 1 and selected.range[2] == 1,
    "compile_selected should preserve the requested range"
)
assert(selected.source, "compile_selected should report a fragment source path")
assert(
    selected.source_mode == "stdin",
    "built-in selected fragment compile should use stdin by default"
)
local fragment_output_dir = typst_test_cache_path("compiler-command-fragments")
assert(selected.output:find(fragment_output_dir, 1, true) == 1, selected.output)
assert(
    selected.project.fragment.parent == project.key,
    "fragment project should record the parent project"
)
assert(
    typst_test_compiler(project).status == "error",
    "selected fragment compile should not mutate the registered project status"
)
assert(
    selected.source_text and selected.source_text:find("= Main", 1, true),
    "fragment source should contain the selection"
)
assert(
    vim.tbl_contains(typst_test_compiler(selected.project).last_command, "-"),
    "built-in selected fragment compile should pass stdin to typst"
)

local selected_completed = vim.wait(10000, function()
    return selected_done
end, 20)
assert(selected_completed, "selected Typst compile did not finish")
assert(
    selected_code == 0,
    ("expected selected compile success, got %s"):format(
        vim.inspect(selected_code)
    )
)
assert(
    selected_fragment == selected.project,
    "selected compile callback should receive the fragment project"
)
assert(
    vim.fn.filereadable(selected.output) == 1,
    ("missing selected output %s"):format(selected.output)
)
assert(
    vim.fn.filereadable(selected.source) == 0,
    "selected fragment source should be removed after compile"
)
assert(
    typst_test_compiler(selected.project).process == nil,
    "fragment project should clear one-shot compile process after success"
)

local fragment_modes = root .. "/tests/fixtures/basic/fragment-modes.typ"
vim.cmd.edit(fragment_modes)
typst.project.set_main(fragment_modes)

local function compile_fragment_template(
    template,
    line1,
    line2,
    expected_source
)
    local done = false
    local code = nil
    local run = typst.compiler.compile_selected({
        notify = false,
        template = template,
        line1 = line1,
        line2 = line2,
        range = 1,
    }, function(result)
        code = result.code
        done = true
    end)
    assert(
        run.ok == true,
        ("compile_selected should start %s fragment compilation"):format(
            template
        )
    )
    assert(
        run.template == template,
        ("compile_selected should preserve %s template name"):format(template)
    )
    assert(run.source, ("missing %s fragment source path"):format(template))
    assert(
        run.source_mode == "stdin",
        ("%s fragment compile should use stdin by default"):format(template)
    )

    local source = run.source_text or ""
    assert(
        source:find(expected_source, 1, true),
        ("%s fragment source missing %q:\n%s"):format(
            template,
            expected_source,
            source
        )
    )

    assert(
        vim.wait(10000, function()
            return done
        end, 20),
        ("%s Typst fragment compile did not finish"):format(template)
    )
    assert(
        code == 0,
        ("expected %s fragment compile success, got %s"):format(
            template,
            vim.inspect(code)
        )
    )
    assert(
        vim.fn.filereadable(run.output) == 1,
        ("missing %s fragment output %s"):format(template, run.output)
    )
    assert(
        vim.fn.filereadable(run.source) == 0,
        ("%s fragment source should be removed after compile"):format(template)
    )
    assert(
        typst_test_compiler(run.project).process == nil,
        ("%s fragment project should clear one-shot compile process"):format(
            template
        )
    )
    return source
end

compile_fragment_template("math", 2, 2, "$ alpha + beta $")
compile_fragment_template(
    "code",
    3,
    4,
    "#{\nlet fragment_value = 40\nfragment_value + 2\n}"
)
compile_fragment_template("full-page", 1, 1, "Fragment markup")
compile_fragment_template(
    "auto-sized",
    1,
    1,
    "#set page(width: auto, height: auto, margin: 0pt)\nFragment markup"
)

local invalid_output_fragment = typst.compiler.compile_selected({
    notify = false,
    line1 = 1,
    line2 = 1,
    range = 1,
    output_name = "nested/fragment",
})
assert(
    invalid_output_fragment.ok == false,
    "compile_selected should report invalid fragment output paths"
)
assert(
    invalid_output_fragment.reason == "output_path_invalid",
    "compile_selected should classify fragment output path failures"
)
assert(
    invalid_output_fragment.source,
    "invalid fragment output should report the planned source path"
)
assert(
    vim.fn.filereadable(invalid_output_fragment.source) == 0,
    "invalid fragment output should not leave a generated source file"
)

vim.cmd("qa!")
