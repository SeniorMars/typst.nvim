local main_file = require("typst.project.main_file")

local M = {}

local function readable(bufnr, path, main, source)
    return main_file.discard_unreadable(bufnr, path, main, source)
end

function M.buffer(bufnr, path, root)
    return readable(bufnr, path, main_file.buffer_main(bufnr, root))
end

function M.persisted(bufnr, path, opts)
    return readable(bufnr, path, main_file.persisted(path, opts))
end

function M.directive(bufnr, path)
    return readable(bufnr, path, main_file.directive(path, bufnr))
end

function M.configured(bufnr, path, root, opts)
    return readable(bufnr, path, main_file.configured(path, bufnr, root, opts))
end

function M.project_file(bufnr, path)
    local main, source, root, root_source = main_file.project_file(path)
    main, source = readable(bufnr, path, main, source)
    return main, source, root, root_source
end

function M.fallback(path, root, scratch)
    if scratch then
        return path, "unnamed buffer"
    end
    return main_file.heuristic(path, root)
end

M.confidence_for_source = main_file.confidence_for_source

return M
