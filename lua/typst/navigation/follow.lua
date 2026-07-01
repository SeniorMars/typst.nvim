local index = require("typst.index")
local follow_context = require("typst.navigation.follow_context")
local follow_lsp = require("typst.navigation.follow_lsp")
local follow_patterns = require("typst.navigation.follow_patterns")
local log = require("typst.core.log")
local open_helper = require("typst.core.open")
local package_info = require("typst.package.info")
local telemetry = require("typst.core.telemetry")
local util = require("typst.core.util")

local M = {}

local function call_user_callback(callback, ...)
    if type(callback) ~= "function" then
        return
    end

    local ok, err = pcall(callback, ...)
    if not ok then
        log.add("warn", "navigation follow callback failed", {
            error = err,
        })
    end
end

local function find_label(collected, name, project)
    for _, item in ipairs(collected.labels or {}) do
        if item.name == name then
            return follow_context.target_location("label", item.source, {
                name = name,
                bufnr = follow_context.buffer_for_project_path(
                    project,
                    item.source and item.source.path
                ),
                provider = "project",
                semantic = false,
            })
        end
    end
end

local function find_citation(collected, name, project)
    for _, item in ipairs(collected.citations or {}) do
        if item.name == name then
            return follow_context.target_location("citation", item.source, {
                name = name,
                bufnr = follow_context.buffer_for_project_path(
                    project,
                    item.source and item.source.path
                ),
                provider = "project",
                semantic = false,
            })
        end
    end
end

local function imported_binding_visible(item, project, current_path)
    local source_path = item.source and item.source.path
    return not source_path
        or util.same_path(source_path, current_path)
        or (project and util.same_path(source_path, project.main))
end

local function find_definition(collected, name, project, current_path)
    for _, item in ipairs(collected.imported_bindings or {}) do
        if
            item.name == name
            and item.definition
            and imported_binding_visible(item, project, current_path)
        then
            return follow_context.target_location(
                "definition",
                item.definition,
                {
                    name = name,
                    imported_name = item.imported_name,
                    bufnr = follow_context.buffer_for_project_path(
                        project,
                        item.definition and item.definition.path
                    ),
                    provider = "project",
                    semantic = false,
                }
            )
        end
    end

    for _, item in ipairs(collected.definitions or {}) do
        if item.name == name then
            return follow_context.target_location("definition", item.source, {
                name = name,
                bufnr = follow_context.buffer_for_project_path(
                    project,
                    item.source and item.source.path
                ),
                provider = "project",
                semantic = false,
            })
        end
    end
end

local function static_target(bufnr, opts)
    local row, col = follow_context.cursor_position(opts)
    if not row or not col then
        return nil
    end
    local project = follow_context.project_for(bufnr)
    local line = follow_context.line_at(bufnr, row)
    local context = follow_context.source_context_at(bufnr, row, col)

    if context.comment or context.raw then
        return nil
    end

    local url = follow_patterns.url_at(line, col)
    if url then
        return url
    end

    if context.code or context.string then
        local quoted = follow_patterns.quoted_target(
            line,
            follow_patterns.quoted_at(line, col),
            follow_context.source_base(bufnr, project)
        )
        if quoted then
            return quoted
        end
    end

    if context.string then
        return nil
    end

    local collected = index.collect({ bufnr = bufnr, project = project }) or {}
    local citation_name = follow_patterns.citation_label_at(line, col)
    if citation_name then
        return find_citation(collected, citation_name, project)
    end

    local label_name = follow_patterns.delimited_label_at(line, col)
    if label_name then
        return find_label(collected, label_name, project)
    end

    local reference_name = follow_patterns.reference_at(line, col)
    if reference_name then
        local target = find_label(collected, reference_name, project)
            or find_citation(collected, reference_name, project)
        if target then
            return target
        end

        local trimmed = reference_name:gsub("[%.,;:]+$", "")
        if trimmed ~= reference_name then
            return find_label(collected, trimmed, project)
                or find_citation(collected, trimmed, project)
        end
    end

    local token = follow_patterns.word_at(line, col)
    if token then
        local fallback = find_definition(
            collected,
            token,
            project,
            follow_context.buffer_path(bufnr)
        )
        if
            type(opts.callback) == "function"
            and follow_lsp.can_request_async(bufnr, opts)
        then
            -- Prefer a precise Tinymist definition when the caller can handle
            -- async, but keep the static project-index target as fallback.
            follow_lsp.definition_async(bufnr, opts, function(target, result)
                opts.callback(target or fallback, result)
            end)
            return {
                ok = false,
                pending = true,
                provider = "tinymist",
                kind = "definition",
            }
        end

        -- Synchronous callers get best-effort local navigation first; LSP is
        -- only used when it can answer synchronously.
        return follow_lsp.definition(bufnr, opts) or fallback
    end
end

local function open_file_target(target, opts)
    local opened, err
    if target.bufnr and vim.api.nvim_buf_is_valid(target.bufnr) then
        opened, err = open_helper.buffer(target.bufnr, opts)
    else
        opened, err = open_helper.file(target.path, opts)
    end

    if not opened then
        vim.notify(
            ("Could not open target: %s"):format(err or "unknown error"),
            vim.log.levels.WARN,
            { title = "typst.nvim" }
        )
        return nil
    end

    if target.lnum then
        local cursor, cursor_err = open_helper.cursor(
            opened.winid,
            opened.bufnr,
            target.lnum,
            target.col
        )
        if not cursor then
            vim.notify(
                ("Could not jump to target: %s"):format(
                    cursor_err or "unknown error"
                ),
                vim.log.levels.WARN,
                { title = "typst.nvim" }
            )
            return nil
        end
    end

    return opened
end

local function open_target(target, opts)
    if target.kind == "url" then
        local opened, err = open_helper.url(target.url)
        if not opened then
            vim.notify(
                ("Could not open URL: %s"):format(err),
                vim.log.levels.WARN,
                { title = "typst.nvim" }
            )
        end
        return
    end

    if target.kind == "package" then
        package_info.info({ query = target.spec })
        return
    end

    if target.path then
        open_file_target(target, opts)
    end
end

--- Resolve the target under the cursor without opening it.
---@param opts? table Follow options, including buffer, cursor position, semantic fallback, and callback.
---@return TypstFollowTarget|table|nil target Static target, pending semantic request, or nil when unresolved.
function M.resolve(opts)
    opts = opts or {}
    local bufnr = follow_context.normalize_bufnr(opts.bufnr)
    return telemetry.time("navigation.follow.resolve", function()
        return static_target(bufnr, opts)
    end)
end

--- Resolve and optionally open the target under the cursor.
---@param opts? table Follow options; `open=false` only resolves and returns the target.
---@return TypstFollowTarget|table|nil target Opened target, pending semantic request, or nil when unresolved.
function M.follow(opts)
    opts = opts or {}
    local user_callback = opts.callback
    local target = M.resolve(vim.tbl_extend("force", opts, {
        callback = function(resolved, result)
            if resolved and opts.open ~= false then
                open_target(resolved, opts)
            end
            call_user_callback(user_callback, resolved, result)
        end,
    }))
    if type(target) == "table" and target.pending then
        return target
    end

    if not target then
        call_user_callback(user_callback, nil)
        return nil
    end

    if opts.open ~= false then
        open_target(target, opts)
    end

    call_user_callback(user_callback, target)

    return target
end

return M
