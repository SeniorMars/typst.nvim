local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local helpers = dofile(root .. "/tests/helpers.lua")
local compiler_api = require("typst.compiler.api")
local typst = require("typst")
local util = require("typst.core.util")

local base = helpers.cache_path("heuristic-confidence")
vim.fn.delete(base, "rf")
vim.fn.mkdir(base .. "/examples", "p")
vim.fn.mkdir(base .. "/.git", "p")
vim.fn.writefile({ "= Book" }, base .. "/main.typ")
vim.fn.writefile({ "= Example" }, base .. "/examples/standalone.typ")

local notifications = {}
typst.reset({ force = true })
typst.setup({
    output_dir = helpers.cache_path("heuristic-confidence-output"),
    compile = {
        provider = {
            name = "noop-compiler",
            compile = function(_project, callback)
                callback({
                    ok = true,
                    code = 0,
                    stdout = "",
                    stderr = "",
                })
                return {
                    ok = true,
                    code = 0,
                }
            end,
            start = function(_project, callback)
                callback({
                    ok = true,
                    code = 0,
                    stdout = "",
                    stderr = "",
                })
                return {
                    ok = true,
                    code = 0,
                }
            end,
            stop = function(_project, callback)
                if callback then
                    callback({ ok = true, code = 0, stopped = true })
                end
                return nil
            end,
            status = function()
                return "idle"
            end,
            output = function()
                return nil
            end,
        },
    },
    project = {
        import_scan = false,
    },
})

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, base .. "/examples/standalone.typ")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "= Example" })
vim.api.nvim_set_current_buf(bufnr)
local project = assert(typst.project.attach(bufnr))
assert(
    project.main == util.normalize(base .. "/main.typ"),
    "nested file should use root main.typ heuristic in this fixture"
)
assert(
    project.main_confidence == "low",
    "root main.typ heuristic should be low confidence"
)
assert(
    project.main_confidence_source == "root heuristic main.typ",
    "root main.typ heuristic should be recorded as the confidence source"
)
project = assert(typst.project.attach(bufnr))
assert(
    project.main_confidence == "low",
    "existing graph reattach should preserve heuristic low confidence"
)
assert(
    project.main_confidence_source == "root heuristic main.typ",
    "existing graph reattach should preserve the original confidence source"
)

compiler_api.compile(project, {}, nil, function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end)

assert(
    notifications[1]
        and notifications[1].level == vim.log.levels.WARN
        and notifications[1].message:find("guessed the Typst main", 1, true),
    "compile should warn once before using a low-confidence main"
)

compiler_api.compile(project, {}, nil, function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end)

local warnings = 0
for _, notification in ipairs(notifications) do
    if notification.level == vim.log.levels.WARN then
        warnings = warnings + 1
    end
end
assert(warnings == 1, "low-confidence main warning should be once per project")

local single = base .. "/single.typ"
vim.fn.writefile({ "= Single" }, single)
local single_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(single_bufnr, single)
vim.api.nvim_buf_set_lines(single_bufnr, 0, -1, false, { "= Single" })
vim.api.nvim_set_current_buf(single_bufnr)
local single_project = assert(typst.project.attach(single_bufnr))
assert(
    single_project.main_confidence == "low",
    "current-buffer fallback should still be visible as low confidence"
)
assert(
    single_project.main_confidence_source == "current buffer",
    "current-buffer fallback should record its confidence source"
)

notifications = {}
compiler_api.compile(single_project, {}, nil, function(message, level)
    notifications[#notifications + 1] = {
        message = message,
        level = level,
    }
end)
for _, notification in ipairs(notifications) do
    assert(
        notification.level ~= vim.log.levels.WARN,
        "current-buffer fallback should not warn on compile"
    )
end
