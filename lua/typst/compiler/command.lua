local util = require("typst.core.util")
local compiler_service = require("typst.project.services.compiler")
local scratch_policy = require("typst.compiler.scratch_policy")

local M = {}

--- Build Typst CLI arguments for compile or watch.
---@param kind '"compile"'|'"watch"' Typst subcommand to build.
---@param project table Project state with root/main and initialized output path.
---@param opts table Effective run configuration.
---@return string[] args Arguments after the executable.
---@return string? deps_path Temporary dependency JSON path when deps are enabled.
function M.build_args(kind, project, opts)
    local supported, scratch_result = scratch_policy.check(project, kind, opts)
    if not supported then
        error(
            scratch_policy.error_message(scratch_result or {
                reason = "unsupported",
                message = ("%s is not supported for this project"):format(kind),
            }),
            2
        )
    end

    local stdin_source = opts.compile and opts.compile.stdin

    local deps_path = nil
    local args = {
        kind,
        "--root",
        project.root,
    }

    for _, arg in ipairs(opts.compile.extra_args or {}) do
        args[#args + 1] = arg
    end

    if kind == "watch" and (opts.compile.watch_output or "auto") ~= "human" then
        for _, arg in ipairs(opts.compile.watch_structured_args or {}) do
            args[#args + 1] = arg
        end
    end

    if opts.compile.deps then
        deps_path = vim.fn.tempname() .. ".json"
        args[#args + 1] = "--deps"
        args[#args + 1] = deps_path
        args[#args + 1] = "--deps-format"
        args[#args + 1] = "json"
    end

    if opts.compile.typst_open then
        args[#args + 1] = "--open"
    end

    local output = (compiler_service.get(project) or {}).output
    if type(output) ~= "string" or output == "" then
        error("typst.nvim: compiler output path is not initialized")
    end

    if kind == "compile" and type(stdin_source) == "string" then
        args[#args + 1] = "-"
    else
        args[#args + 1] = project.main
    end
    args[#args + 1] = output

    return args, deps_path
end

--- Build the full Typst command for compile or watch.
---@param kind '"compile"'|'"watch"' Typst subcommand to build.
---@param project table Project state with root/main and initialized output path.
---@param opts table Effective run configuration.
---@return string[] command Executable plus CLI arguments.
---@return string? deps_path Temporary dependency JSON path when deps are enabled.
function M.build(kind, project, opts)
    local args, deps_path = M.build_args(kind, project, opts)
    local command = vim.list_extend(
        util.command_prefix(opts.executable),
        vim.deepcopy(args)
    )
    return command, deps_path
end

return M
