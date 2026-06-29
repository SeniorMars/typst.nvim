local label_actions = require("typst.ui.label_actions")
local lexical = require("typst.syntax.lexical")
local project_registry = require("typst.project")
local graph_service = require("typst.project.services.graph")
local tinymist = require("typst.integrations.tinymist")
local util = require("typst.core.util")

local M = {}

local function resolve_project(bufnr)
    local state = project_registry.get(bufnr)
    if state then
        return state
    end

    local ok, resolved = pcall(project_registry.resolve, bufnr)
    return ok and resolved or nil
end

local function read_file(path)
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or {}
end

local function known_project_files(project)
    local files = {}
    local seen = {}
    local function add(path)
        local normalized = path and util.normalize(path)
        local key = path and util.path_key(path) or nil
        if
            normalized
            and key
            and not seen[key]
            and vim.fn.filereadable(normalized) == 1
        then
            seen[key] = true
            files[#files + 1] = normalized
        end
    end

    if project then
        local graph = graph_service.get(project) or {}
        add(project.main)
        for path in pairs(graph.files or {}) do
            add(path)
        end
        for path in pairs(graph.dependencies or {}) do
            add(path)
        end
        for bufnr in pairs(project.bufs or {}) do
            add(
                vim.api.nvim_buf_is_valid(bufnr)
                        and vim.api.nvim_buf_get_name(bufnr)
                    or nil
            )
        end
    end

    return files
end

local function code_only_lines(lines)
    return lexical.mask_lines(lines, {
        strings = "space",
        comments = "space",
        raw = "space",
    })
end

local function find_word_occurrences(project, name)
    local occurrences = {}
    if type(name) ~= "string" or name == "" then
        return occurrences
    end

    local pattern = ("%%f[%%w_.%%-]%s%%f[^%%w_.%%-]"):format(vim.pesc(name))
    for _, path in ipairs(known_project_files(project)) do
        local lines = read_file(path)
        for row, code_line in ipairs(code_only_lines(lines)) do
            local search_at = 1
            while true do
                local start_col, end_col = code_line:find(pattern, search_at)
                if not start_col then
                    break
                end
                occurrences[#occurrences + 1] = {
                    source = {
                        path = path,
                        lnum = row,
                        col = start_col,
                    },
                    text = lines[row],
                }
                search_at = end_col + 1
            end
        end
    end
    return occurrences
end

local function project_file_filter(project)
    if not project then
        return nil
    end

    local files = {}
    local function add(path)
        if not path or path == "" then
            return
        end

        files[util.path_key(path)] = true
        local normalized = util.normalize(path)
        if normalized then
            files[util.path_key(normalized)] = true
        end
    end

    add(project.main)
    local graph = graph_service.get(project) or {}
    for path in pairs(graph.files or {}) do
        add(path)
    end
    for path in pairs(graph.dependencies or {}) do
        add(path)
    end
    for bufnr in pairs(project.bufs or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            add(vim.api.nvim_buf_get_name(bufnr))
        end
    end

    return files
end

local function semantic_reference_items(bufnr, pos, project, opts)
    opts = opts or {}
    if opts.semantic == false then
        return nil
    end

    return nil
end

local function semantic_reference_items_async(
    bufnr,
    pos,
    project,
    opts,
    callback
)
    opts = opts or {}
    if opts.semantic == false then
        return nil
    end

    local has_async_client = false
    for _, client in ipairs(tinymist.clients(bufnr)) do
        if type(client.request) == "function" then
            has_async_client = true
            break
        end
    end
    if not has_async_client then
        return nil
    end

    local ok, pending = pcall(tinymist.references, bufnr, {
        timeout_ms = opts.timeout_ms,
        pos = pos,
        include_declaration = true,
        callback = function(result)
            if not result.ok then
                callback(nil, result)
                return
            end

            local files = project_file_filter(project)
            local items = {}
            for _, reference in ipairs(result.references or {}) do
                local raw_path = reference.file
                local source = {
                    path = raw_path and util.normalize(raw_path) or nil,
                    lnum = reference.lnum or 1,
                    col = reference.col or 1,
                }
                if
                    source.path
                    and (
                        not files
                        or files[util.path_key(raw_path)]
                        or files[util.path_key(source.path)]
                    )
                then
                    local item = label_actions.source_to_qf_item(
                        source,
                        label_actions.source_line(source) or ""
                    )
                    if item then
                        item.user_data = {
                            provider = "tinymist",
                            semantic = true,
                        }
                        items[#items + 1] = item
                    end
                end
            end

            callback(#items > 0 and items or nil, result)
        end,
    })
    if ok then
        return pending
    end
end

function M.add_definition_actions(actions, target, bufnr, pos, opts)
    if not target or target.kind ~= "definition" or not target.name then
        return
    end

    local action_pos = pos and { pos[1], pos[2] } or nil
    opts = opts or {}
    actions[#actions + 1] = {
        id = "definition_references",
        title = ("List occurrences of %s"):format(target.name),
        kind = "reference",
        target = target,
        run = function(run_opts)
            run_opts = run_opts or {}
            local project = resolve_project(bufnr)
            local function open_occurrences()
                local occurrences = find_word_occurrences(project, target.name)
                local items = {}
                for _, occurrence in ipairs(occurrences) do
                    local item = label_actions.source_to_qf_item(
                        occurrence.source,
                        occurrence.text
                    )
                    if item then
                        items[#items + 1] = item
                    end
                end
                return label_actions.open_quickfix(
                    ("Typst occurrences: %s"):format(target.name),
                    items,
                    run_opts
                )
            end

            local pending = semantic_reference_items_async(
                bufnr,
                action_pos,
                project,
                vim.tbl_extend("force", opts, run_opts or {}),
                function(semantic_items_result)
                    local opened
                    if semantic_items_result then
                        opened = label_actions.open_quickfix(
                            ("Typst references: %s"):format(target.name),
                            semantic_items_result,
                            run_opts
                        )
                        if type(run_opts.callback) == "function" then
                            run_opts.callback(opened, {
                                ok = true,
                                provider = "tinymist",
                                semantic = true,
                            })
                        end
                        return
                    end
                    opened = open_occurrences()
                    if type(run_opts.callback) == "function" then
                        run_opts.callback(opened, {
                            ok = true,
                            provider = "syntax",
                            semantic = false,
                        })
                    end
                end
            )
            if type(pending) == "table" and pending.provider == "tinymist" then
                return pending
            end
            local semantic_items_result = semantic_reference_items(
                bufnr,
                action_pos,
                project,
                vim.tbl_extend("force", opts, run_opts or {})
            )
            if semantic_items_result then
                return label_actions.open_quickfix(
                    ("Typst references: %s"):format(target.name),
                    semantic_items_result,
                    run_opts
                )
            end
            return open_occurrences()
        end,
    }
end

return M
