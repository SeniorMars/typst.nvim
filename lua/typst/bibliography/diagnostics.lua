local index = require("typst.index")
local parser = require("typst.bibliography.parser")
local quickfix = require("typst.diagnostics.quickfix")
local project_context = require("typst.project.context")
local index_service = require("typst.project.services.index")
local util = require("typst.core.util")

local M = {}

M.namespace = vim.api.nvim_create_namespace("typst.nvim.bibliography")

-- Bibliography diagnostics are project-scoped, not global. Two projects can use
-- the same citation key differently, so each project gets its own namespace and
-- tracked buffer set for clearing.
local buffers_by_project = {}

--- Return the bibliography diagnostics namespace for a project.
---@param project? table Project state, or nil for the global fallback namespace.
---@return integer namespace Neovim diagnostic namespace id.
function M.namespace_for(project)
    if not project then
        return M.namespace
    end
    if not project.bibliography_diagnostics_namespace then
        project.bibliography_diagnostics_namespace =
            vim.api.nvim_create_namespace(
                "typst.nvim.bibliography:"
                    .. tostring(project.key or project.main)
            )
    end
    return project.bibliography_diagnostics_namespace
end

local function diagnostic_buffer(path)
    local bufnr = util.loaded_buffer_for_path(path)
    if bufnr then
        return bufnr
    end

    return vim.fn.bufadd(path)
end

local function source_of(item, fallback)
    local source = item and item.source or {}
    return {
        path = source.path or fallback,
        lnum = source.lnum or 1,
        col = source.col or 1,
    }
end

local function add(by_buffer, project, source, severity, message)
    if not source or not source.path then
        return
    end

    local bufnr = diagnostic_buffer(source.path)
    by_buffer[bufnr] = by_buffer[bufnr] or {}
    by_buffer[bufnr][#by_buffer[bufnr] + 1] = {
        lnum = math.max((source.lnum or 1) - 1, 0),
        col = math.max((source.col or 1) - 1, 0),
        end_lnum = math.max((source.lnum or 1) - 1, 0),
        end_col = math.max(source.col or 1, 1),
        severity = severity,
        source = "typst bibliography",
        message = message,
        user_data = {
            typst = {
                project = project.key,
            },
        },
    }
end

local function parse_bibliography_entries(path)
    local ext = vim.fn.fnamemodify(path, ":e"):lower()
    local entries = {}
    if ext == "bib" then
        entries = parser.parse_bibtex_file(path)
    elseif ext == "yml" or ext == "yaml" then
        entries = parser.parse_hayagriva_file(path)
    end

    return vim.tbl_map(function(entry)
        return {
            name = entry.key,
            kind = "citation",
            source = {
                path = path,
                lnum = entry.lnum or 1,
                col = entry.col or 1,
            },
            fields = vim.deepcopy(entry.fields or {}),
        }
    end, entries)
end

local function cached_bibliography_entries(project, path)
    local project_index = index_service.get(project) or {}
    local cached = project_index.bibliographies
        and project_index.bibliographies[util.path_key(path)]
    local record = cached and cached.record
    local data = record and record.data
    local entries = data and data.all_citations
    if type(entries) ~= "table" or #entries == 0 then
        return nil
    end

    return vim.tbl_map(function(entry)
        return vim.deepcopy(entry)
    end, entries)
end

local function collect_entries(project, collected)
    local by_key = {}
    local all = {}

    local paths = {}
    for path in pairs((collected or {}).bibliography_paths or {}) do
        paths[#paths + 1] = path
    end
    table.sort(paths)

    for _, path in ipairs(paths) do
        if vim.fn.filereadable(path) == 1 then
            local entries = cached_bibliography_entries(project, path)
                or parse_bibliography_entries(path)
            for _, item in ipairs(entries) do
                if item.name then
                    by_key[item.name] = by_key[item.name] or {}
                    by_key[item.name][#by_key[item.name] + 1] = item
                    all[#all + 1] = item
                end
            end
        end
    end

    if #all == 0 then
        local project_index = index_service.get(project) or {}
        for _, bibliography in pairs(project_index.bibliographies or {}) do
            for _, item in ipairs(bibliography.citations or {}) do
                if item.name then
                    by_key[item.name] = by_key[item.name] or {}
                    by_key[item.name][#by_key[item.name] + 1] = item
                    all[#all + 1] = item
                end
            end
        end
    end

    return by_key, all
end

local function collect_used_citations(collected)
    local used = {}
    local explicit_missing = {}

    for _, reference in ipairs((collected or {}).references or {}) do
        local name = reference.reference_target_name or reference.name
        if
            name
            and (
                reference.reference_target == "citation"
                or reference.reference_style == "cite"
            )
        then
            used[name] = true
        end
        if
            name
            and reference.reference_style == "cite"
            and reference.reference_target ~= "citation"
        then
            explicit_missing[#explicit_missing + 1] = reference
        end
    end

    return used, explicit_missing
end

local function label_names(collected)
    local labels = {}
    for _, item in ipairs((collected or {}).labels or {}) do
        if item.name then
            labels[item.name] = item
        end
    end
    return labels
end

local function diagnostic_total(by_buffer)
    local total = 0
    for _, diagnostics in pairs(by_buffer or {}) do
        total = total + #diagnostics
    end
    return total
end

local function publish(project, by_buffer)
    M.clear(project)
    local tracked = {}
    local namespace = M.namespace_for(project)
    for bufnr, diagnostics in pairs(by_buffer) do
        vim.diagnostic.set(namespace, bufnr, diagnostics)
        tracked[bufnr] = true
    end
    buffers_by_project[project.key] = tracked
end

--- Clear published bibliography diagnostics for a project.
---@param project_or_opts? table Project state or options used to resolve one.
---@return boolean cleared True when a project was found and cleared.
function M.clear(project_or_opts)
    local project = type(project_or_opts) == "table"
            and project_or_opts.root
            and project_or_opts
        or project_context.resolve(project_or_opts or {})
    if not project then
        return false
    end

    for bufnr in pairs(buffers_by_project[project.key] or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.diagnostic.set(M.namespace_for(project), bufnr, {})
        end
    end
    buffers_by_project[project.key] = nil
    return true
end

--- Check bibliography references and publish bibliography diagnostics.
---@param opts? table Diagnostic options such as project, quickfix, and checks to skip.
---@return table result Diagnostic summary with diagnostics grouped by buffer.
function M.check(opts)
    opts = opts or {}
    local project = project_context.resolve(opts)
    if not project then
        return {
            ok = false,
            diagnostics = 0,
            by_buffer = {},
            message = "no Typst project",
        }
    end

    local collected = index.collect({ project = project }) or {}
    local entries_by_key = collect_entries(project, collected)
    local used, explicit_missing = collect_used_citations(collected)
    local labels = label_names(collected)
    local by_buffer = {}

    -- Validate citation health against the project index so labels, references,
    -- and bibliography entries are compared with the same root/main semantics as
    -- navigation and completion.
    if opts.undefined ~= false then
        for _, reference in ipairs(explicit_missing) do
            add(
                by_buffer,
                project,
                source_of(reference, project.main),
                vim.diagnostic.severity.ERROR,
                ("Undefined citation `%s`"):format(reference.name)
            )
        end
    end

    if opts.duplicates ~= false then
        for key, entries in pairs(entries_by_key) do
            if #entries > 1 then
                for index_in_key = 2, #entries do
                    add(
                        by_buffer,
                        project,
                        source_of(entries[index_in_key], project.main),
                        vim.diagnostic.severity.WARN,
                        ("Duplicate bibliography key `%s`"):format(key)
                    )
                end
            end
        end
    end

    if opts.unused ~= false then
        for key, entries in pairs(entries_by_key) do
            if not used[key] then
                add(
                    by_buffer,
                    project,
                    source_of(entries[1], project.main),
                    vim.diagnostic.severity.HINT,
                    ("Unused bibliography entry `%s`"):format(key)
                )
            end
        end
    end

    if opts.collisions ~= false then
        for key, entries in pairs(entries_by_key) do
            if labels[key] then
                add(
                    by_buffer,
                    project,
                    source_of(entries[1], project.main),
                    vim.diagnostic.severity.WARN,
                    ("Bibliography key `%s` also exists as a label"):format(key)
                )
            end
        end
    end

    publish(project, by_buffer)

    local qf_items = {}
    if opts.quickfix or opts.open then
        qf_items = quickfix.items(by_buffer, {
            type_map = {
                [vim.diagnostic.severity.ERROR] = "E",
            },
            default_type = "W",
        })
        vim.fn.setqflist({}, "r", {
            title = ("typst.nvim bibliography: %s"):format(
                util.relpath(project.main, project.root)
            ),
            items = qf_items,
        })
        if opts.open and #qf_items > 0 then
            vim.cmd("copen")
        end
    end

    return {
        ok = true,
        project = project,
        diagnostics = diagnostic_total(by_buffer),
        by_buffer = by_buffer,
        quickfix = qf_items,
    }
end

return M
