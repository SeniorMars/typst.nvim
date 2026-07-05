local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local typst = require("typst")
local compiler_command = require("typst.compiler.command")
local compiler = require("typst.compiler")
local config = require("typst.config")
local project_store = require("typst.project.store")
local helpers = require("tests.helpers")

typst.reset({ force = true })
typst.setup({
    root = root,
    executable = helpers.python_command(
        root .. "/tests/fixtures/fake-typst-integration.py"
    ),
    output_dir = typst_test_cache_path("compiler-scratch-output"),
})
vim.cmd.enew()
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "typst"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "= Unsaved",
    "Scratch body",
})
local snapshot = assert(typst.project.attach(bufnr), "scratch should attach")
assert(snapshot.scratch == true, "public snapshot should mark scratch project")
local live = assert(
    project_store.project_for_buffer(bufnr),
    "scratch project should have live state"
)

local compile_result = nil
local compile_handle = typst.compiler.compile(
    { notify = false },
    function(result)
        compile_result = result
    end
)
assert(compile_handle == nil, "scratch compile should not spawn Typst")
assert(
    compile_result and compile_result.reason == "scratch_compile_unsupported",
    "scratch compile should return an actionable structured error"
)
assert(
    typst_test_compiler(live).process == nil,
    "scratch compile should not install an active process"
)
assert(
    typst_test_compiler(live).output_lease == nil,
    "scratch compile should not acquire an output lease"
)

local stdin_run_config = vim.deepcopy(config.unsafe_get())
stdin_run_config.compile.stdin = "= Stdin fragment"
local stdin_args =
    assert(compiler_command.build_args("compile", live, stdin_run_config))
assert(
    stdin_args[#stdin_args - 1] == "-",
    "scratch stdin compile should use typst compile - instead of the synthetic main path"
)

local record_dir = typst_test_cache_path("compiler-scratch-stdin-record")
vim.fn.delete(record_dir, "rf")
vim.fn.mkdir(record_dir, "p")
vim.env.TYPST_NVIM_FAKE_TYPST_RECORD_DIR = record_dir
local stdin_done = false
local stdin_result = nil
local stdin_handle = compiler.compile(live, function(result)
    stdin_result = result
    stdin_done = true
end, stdin_run_config)
assert(stdin_handle ~= nil, "scratch stdin compile should start fake Typst")
assert(
    vim.wait(10000, function()
        return stdin_done
    end, 20),
    "scratch stdin compile should finish"
)
vim.env.TYPST_NVIM_FAKE_TYPST_RECORD_DIR = nil
assert(
    stdin_result and stdin_result.code == 0,
    "scratch stdin compile should succeed through the full runner"
)
local stdin_state = typst_test_compiler(live)
assert(
    stdin_state.process == nil,
    "scratch stdin compile should clear its process after success"
)
assert(
    stdin_state.output and vim.fn.filereadable(stdin_state.output) == 1,
    "scratch stdin compile should write the configured output"
)
assert(
    stdin_state.output_lease == nil,
    "scratch stdin compile should release output lease after success"
)
local recorded_argv = vim.json.decode(
    table.concat(vim.fn.readfile(record_dir .. "/argv.json"), "\n")
)
assert(
    recorded_argv[#recorded_argv - 1] == "-",
    "fake Typst should receive stdin input marker for scratch compile"
)
local recorded_stdin =
    table.concat(vim.fn.readfile(record_dir .. "/stdin.txt"), "\n")
assert(
    recorded_stdin == stdin_run_config.compile.stdin,
    "fake Typst should receive the scratch fragment source on stdin"
)

local watch_result = nil
local watch_handle = typst.compiler.watch({ notify = false }, function(result)
    watch_result = result
end)
assert(watch_handle == nil, "scratch watch should not spawn Typst")
assert(
    watch_result and watch_result.reason == "scratch_watch_unsupported",
    "scratch watch should return an actionable structured error"
)
assert(
    typst_test_compiler(live).watcher == nil,
    "scratch watch should not install an active watcher"
)
assert(
    typst_test_compiler(live).output_lease == nil,
    "scratch watch should not acquire an output lease"
)

local real_root = typst_test_cache_path("compiler-scratch-file-main")
vim.fn.delete(real_root, "rf")
vim.fn.mkdir(real_root, "p")
local real_main = real_root .. "/main.typ"
vim.fn.writefile({ "= Real Main" }, real_main)

typst.reset({ force = true })
typst.setup({
    root = real_root,
    output_dir = typst_test_cache_path("compiler-scratch-file-main-output"),
})
vim.cmd.enew()
local scratch_with_main = vim.api.nvim_get_current_buf()
vim.bo[scratch_with_main].filetype = "typst"
vim.api.nvim_buf_set_lines(scratch_with_main, 0, -1, false, {
    "#let local-note = [draft]",
})
vim.b[scratch_with_main].typst_main = real_main

local file_snapshot = assert(
    typst.project.attach(scratch_with_main),
    "scratch buffer with explicit real main should attach"
)
assert(
    file_snapshot.scratch == false and file_snapshot.source_kind == "file",
    "project should be file-backed when the main is a real file"
)
local file_project = assert(
    project_store.project_for_buffer(scratch_with_main),
    "file-backed project should have live state"
)
local file_args = assert(
    compiler_command.build_args("compile", file_project, config.unsafe_get())
)
assert(
    file_args[#file_args - 1] == real_main,
    "file-backed project should compile the real explicit main"
)

vim.cmd("qa!")
