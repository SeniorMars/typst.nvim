local lexical = require("typst.syntax.lexical")
local log = require("typst.core.log")
local state_store = require("typst.core.state")
local util = require("typst.core.util")

local M = {}

local directive_scan_lines = 25

local heuristic_main_sources = {
    ["import scan"] = true,
    ["root heuristic main.typ"] = true,
}

local medium_confidence_sources = {
    ["existing project graph"] = true,
    ["import scan"] = true,
}

local low_confidence_sources = {
    ["current buffer"] = true,
    ["root heuristic main.typ"] = true,
}

local function strip_inline_comment(value)
    return lexical.strip_line_comment(value):gsub("%s+#.*$", "")
end

local function strip_wrapping_quotes(value)
    local double_quoted = value:match('^"(.*)"$')
    if double_quoted then
        return double_quoted
    end

    local single_quoted = value:match("^'(.*)'$")
    if single_quoted then
        return single_quoted
    end

    return value
end

local function clean_main_value(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(strip_inline_comment(value))
    value = value:match("^main%s*[:=]%s*(.+)$") or value
    value = vim.trim(strip_wrapping_quotes(vim.trim(value)))

    if value == "" then
        return nil
    end

    return value
end

--- Read the buffer-local explicit Typst main file.
---@param bufnr integer Buffer whose `vim.b.typst_main` should be checked.
---@param root string Root used to resolve relative main paths.
---@return string|nil main Resolved main path from the buffer variable.
---@return string|nil source Source label for the main decision.
function M.buffer_main(bufnr, root)
    local buffer_main = util.get_buf_var(bufnr, "typst_main")
    if type(buffer_main) == "string" and buffer_main ~= "" then
        return util.resolve_path(buffer_main, root),
            "buffer variable vim.b.typst_main"
    end
end

local function main_readable_for_buffer(main, path)
    return main and (util.same_path(main, path) or util.readable(main))
end

--- Drop unreadable main candidates before project attachment commits to them.
---@param bufnr integer Buffer being resolved.
---@param path string Current buffer path.
---@param main? string Main candidate path.
---@param source? string Source label for the main candidate.
---@param opts? {allow_unreadable_explicit_main?:boolean}
---@return string|nil main Readable main path, or nil when discarded.
---@return string|nil source Source label preserved for readable candidates.
function M.discard_unreadable(bufnr, path, main, source, opts)
    if not main then
        return nil
    end

    if main_readable_for_buffer(main, path) then
        return main, source
    end

    if
        opts
        and opts.allow_unreadable_explicit_main == true
        and source == "buffer variable vim.b.typst_main"
    then
        return main, source
    end

    if source == "buffer variable vim.b.typst_main" then
        -- Buffer-local mains are often set interactively. Drop stale values so a
        -- renamed or deleted main does not keep the buffer attached to a dead
        -- project until the user manually clears it.
        util.del_buf_var(bufnr, "typst_main")
    end

    log.add("warn", "ignored unreadable Typst main", {
        buffer = path,
        main = main,
        source = source,
    })
    return nil
end

--- Resolve a persisted explicit main file when project config allows it.
---@param path string Buffer path used as the persistence key.
---@param opts table Plugin configuration containing project persistence settings.
---@return string? main Persisted main file path.
---@return string? source Source label for the persisted decision.
function M.persisted(path, opts)
    if not (opts.project and opts.project.persist_main) then
        return nil
    end

    local main = state_store.explicit_main(path)
    if main then
        return main, "saved explicit main"
    end
end

--- Read a `typst.nvim: main` directive from the document header.
---@param path string Buffer path used to resolve relative directive values.
---@param bufnr integer Buffer whose first lines should be scanned.
---@return string|nil main Resolved directive main path.
---@return string|nil source Source label for directive resolution.
function M.directive(path, bufnr)
    local end_line =
        math.min(vim.api.nvim_buf_line_count(bufnr), directive_scan_lines)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, end_line, false)

    -- Limit directive scanning to the document header. A later example or code
    -- block that mentions typst.nvim: main should not re-root the project.
    for _, line in ipairs(lines) do
        local value = line:match("^%s*//%s*typst%.nvim:%s*main%s*=%s*(.-)%s*$")
            or line:match("^%s*//%s*typst%.nvim:%s*main%s*:%s*(.-)%s*$")
        value = clean_main_value(value)
        if value then
            return util.resolve_path(value, util.dirname(path)),
                "Typst directive typst.nvim: main"
        end
    end
end

--- Resolve the configured main-file policy for a buffer.
---@param path string Buffer path passed to config callbacks.
---@param bufnr integer Buffer number passed to config callbacks.
---@param root string Project root used to resolve relative configured paths.
---@param opts table Plugin configuration containing `main` policy.
---@return string|nil main Configured main path, if any.
---@return string|nil source Source label for configured resolution.
function M.configured(path, bufnr, root, opts)
    if type(opts.main) == "function" then
        local ok, main = xpcall(function()
            return opts.main(bufnr, path, root)
        end, debug.traceback)
        if not ok then
            log.add("warn", "Typst main callback failed", {
                bufnr = bufnr,
                path = path,
                root = root,
                error = main,
            })
            return nil
        end
        return main and util.resolve_path(main, root), "config.main callback"
    end

    if type(opts.main) == "string" and opts.main ~= "" then
        return util.resolve_path(opts.main, root), "config.main"
    end

    if type(opts.main) == "table" then
        local mapped = opts.main[root]
        if mapped == nil then
            for configured_root, value in pairs(opts.main) do
                if util.same_path(util.normalize(configured_root), root) then
                    mapped = value
                    break
                end
            end
        end

        if type(mapped) == "function" then
            local ok, main = xpcall(function()
                return mapped(bufnr, path, root)
            end, debug.traceback)
            if not ok then
                log.add("warn", "Typst main table callback failed", {
                    bufnr = bufnr,
                    path = path,
                    root = root,
                    error = main,
                })
                return nil
            end
            return main and util.resolve_path(main, root),
                "config.main table callback"
        end

        if type(mapped) == "string" and mapped ~= "" then
            return util.resolve_path(mapped, root), "config.main table"
        end
    end
end

--- Resolve a main file from the nearest `.typstmain` project marker.
---@param path string Buffer path used as the upward-search anchor.
---@return string|nil main Main path from `.typstmain`.
---@return string|nil main_source Source label for the main decision.
---@return string|nil root Project root containing `.typstmain`.
---@return string|nil root_source Source label for the project root.
function M.project_file(path)
    local project_files = vim.fs.find(".typstmain", {
        upward = true,
        path = util.dirname(path),
        type = "file",
        limit = 1,
    })
    local project_file = project_files and project_files[1]
    if not project_file then
        return nil
    end

    local project_root = util.dirname(project_file)
    local ok, lines = pcall(vim.fn.readfile, project_file, "", 50)
    if not ok then
        return nil
    end

    for _, line in ipairs(lines) do
        if
            not line:match("^%s*$")
            and not line:match("^%s*#")
            and not line:match("^%s*//")
        then
            local value = clean_main_value(line)
            if value then
                return util.resolve_path(value, project_root),
                    ".typstmain project file",
                    project_root,
                    ".typstmain project file"
            end
        end
    end
end

--- Choose the fallback main file when no explicit policy matched.
---@param path string Current buffer path.
---@param root string Project root candidate used to check `main.typ`.
---@return string main Fallback main path.
---@return string source Source label for the heuristic decision.
function M.heuristic(path, root)
    local root_main = util.join(root, "main.typ")
    if
        util.dirname(path) ~= util.normalize(root) and util.readable(root_main)
    then
        return util.normalize(root_main), "root heuristic main.typ"
    end

    return path, "current buffer"
end

--- Check whether a main-file source label came from fallback heuristics.
---@param source? string Source label to classify.
---@return boolean heuristic True when the source is heuristic.
function M.is_heuristic_source(source)
    return heuristic_main_sources[source] == true
end

--- Return a coarse confidence label for a main-file source.
---@param source? string Source label returned by main resolution.
---@return '"high"'|'"medium"'|'"low"' confidence Resolution confidence.
function M.confidence_for_source(source)
    if low_confidence_sources[source] then
        return "low"
    end
    if medium_confidence_sources[source] then
        return "medium"
    end
    return "high"
end

return M
