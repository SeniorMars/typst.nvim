local project_services = require("typst.project.services")

local M = {}

local function root()
    return vim.fn.getcwd()
end

local function join(...)
    return vim.fs.joinpath(...)
end

local function cache_path(...)
    if _G.typst_test_cache_path then
        return _G.typst_test_cache_path(...)
    end
    return join(vim.fn.stdpath("cache"), "typst.nvim", ...)
end

function M.fixture_path(...)
    return join(root(), "tests", "fixtures", ...)
end

function M.new_state_project(name, fields)
    fields = fields or {}
    local main = fields.main or M.fixture_path("basic", "main.typ")
    return vim.tbl_extend("force", {
        key = name,
        root = fields.root or root(),
        main = main,
        services = project_services.new_state(),
    }, fields)
end

function M.open_typst_project(opts)
    opts = opts or {}
    local typst = require("typst")

    local project_root = opts.root
    local main = opts.main
    if opts.files then
        project_root = project_root or cache_path(opts.name or "helper-project")
        vim.fn.delete(project_root, "rf")
        for path, text in pairs(opts.files) do
            local full_path = join(project_root, path)
            vim.fn.mkdir(vim.fs.dirname(full_path), "p")
            vim.fn.writefile(vim.split(text, "\n", { plain = true }), full_path)
        end
        main = main or join(project_root, "main.typ")
    else
        main = main or M.fixture_path("basic", "main.typ")
        project_root = project_root or root()
    end

    typst.reset({ force = true })
    typst.setup(vim.tbl_extend("force", {
        root = project_root,
        project = {
            import_scan = false,
        },
    }, opts.setup or {}))

    vim.cmd.edit(vim.fn.fnameescape(main))
    vim.bo.filetype = "typst"
    local snapshot = typst.project.set_main(main)
    local state = require("typst.project.store").get(snapshot.key) or snapshot
    return {
        typst = typst,
        root = project_root,
        main = main,
        bufnr = vim.api.nvim_get_current_buf(),
        project = state,
    }
end

return M
