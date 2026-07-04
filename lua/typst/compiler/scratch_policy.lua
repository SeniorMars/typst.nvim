local project_model = require("typst.project.model")

local M = {}

local function is_stdin_compile(kind, opts)
    opts = opts or {}
    return kind == "compile"
        and type(opts.compile) == "table"
        and type(opts.compile.stdin) == "string"
end

local function unsupported_result(kind)
    if kind == "watch" then
        return {
            ok = false,
            code = 1,
            stdout = "",
            stderr = "Save the unnamed Typst buffer before starting watch.",
            reason = "scratch_watch_unsupported",
            message = "Cannot watch an unnamed Typst buffer; save the buffer first.",
            stale = false,
        }
    end

    return {
        ok = false,
        code = 1,
        stdout = "",
        stderr = "Save the unnamed Typst buffer before compiling.",
        reason = "scratch_compile_unsupported",
        message = "Cannot compile an unnamed Typst buffer with the built-in CLI provider; save the buffer first.",
        stale = false,
    }
end

--- Check whether the built-in CLI provider can run for a project.
---
--- Scratch project mains are identity keys, not readable files. They can only
--- be compiled when the caller supplies stdin; watch always needs a saved main.
---@param project TypstProject
---@param kind '"compile"'|'"watch"'
---@param opts? table Effective run configuration.
---@return boolean ok
---@return TypstCompilerResult? result Structured rejection result when unsupported.
function M.check(project, kind, opts)
    if
        not project_model.is_scratch(project) or is_stdin_compile(kind, opts)
    then
        return true
    end
    return false, unsupported_result(kind)
end

--- Return the command-builder error text for an unsupported scratch run.
---@param result TypstCompilerResult
---@return string
function M.error_message(result)
    return "typst.nvim: " .. (result.message or "unsupported scratch project")
end

return M
