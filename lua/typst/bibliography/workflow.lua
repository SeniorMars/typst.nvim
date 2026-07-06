local config = require("typst.config")
local file_edits = require("typst.ui.label_rename_files")
local index = require("typst.index")
local parser = require("typst.bibliography.parser")
local project_context = require("typst.project.context")
local coordinates = require("typst.core.coordinates")
local util = require("typst.core.util")

-- Bibliography workflows are project-scoped on purpose.
--
-- Status, preview, attachment lookup, and key renames combine parsed
-- bibliography files with the Typst reference index so commands update only the
-- citations and bibliography entries reachable from the current project.
local M = {}

local normalize_bufnr = require("typst.core.buffer").normalize_bufnr

local function extension(path)
    return vim.fn.fnamemodify(path or "", ":e"):lower()
end

local function entries_for_path(path)
    local ext = extension(path)
    if ext == "bib" then
        return parser.parse_bibtex_file(path)
    end
    if ext == "yml" or ext == "yaml" then
        return parser.parse_hayagriva_file(path)
    end
    return {}
end

local function entry_for(path, key, lnum)
    for _, entry in ipairs(entries_for_path(path)) do
        if key and entry.key == key then
            return entry
        end
        if lnum and entry.lnum == lnum then
            return entry
        end
    end
end

local function split_keys(value)
    local keys = {}
    for key in tostring(value or ""):gmatch("[^,%s]+") do
        keys[#keys + 1] = key
    end
    return keys
end

local function expand_bibtex_fields(path, key, seen)
    seen = seen or {}
    if seen[key] then
        return {}
    end
    seen[key] = true

    local entry = entry_for(path, key)
    local fields = vim.deepcopy((entry and entry.fields) or {})
    local parents = {}
    if fields.crossref then
        parents[#parents + 1] = fields.crossref
    end
    for _, parent in ipairs(split_keys(fields.xdata)) do
        parents[#parents + 1] = parent
    end

    for _, parent in ipairs(parents) do
        -- BibTeX inheritance can be cyclic through crossref/xdata. Track seen
        -- keys so preview and rename actions do not recurse forever.
        local inherited = expand_bibtex_fields(path, parent, seen)
        for name, value in pairs(inherited) do
            if fields[name] == nil then
                fields[name] = value
            end
        end
    end

    return fields
end

--- Return normalized bibliography fields for one entry.
---@param opts table Entry lookup options containing `path`, `key`/`name`, and optional line.
---@return table fields Expanded BibTeX fields or copied Hayagriva fields.
function M.expanded_fields(opts)
    opts = opts or {}
    local path = opts.path
    local key = opts.key or opts.name
    if not path then
        return {}
    end

    local ext = extension(path)
    if ext == "bib" and key then
        return expand_bibtex_fields(path, key)
    end

    return vim.deepcopy(parser.fields(path, key, opts.lnum) or {})
end

local function field(fields, names)
    for _, name in ipairs(names) do
        local value = fields[name]
        if type(value) == "string" and vim.trim(value) ~= "" then
            return vim.trim(value)
        end
    end
end

local function first_year(fields)
    local value = field(fields, { "year", "date" })
    return value and value:match("%d%d%d%d") or value
end

local searchable_fields = {
    "author",
    "editor",
    "title",
    "year",
    "date",
    "journal",
    "journaltitle",
    "booktitle",
    "keywords",
    "keyword",
    "abstract",
}

local function current_cursor(opts)
    opts = opts or {}
    local bufnr = normalize_bufnr(opts.bufnr)
    local winid = opts.winid
    if winid and not vim.api.nvim_win_is_valid(winid) then
        winid = nil
    end
    winid = winid or vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(winid) ~= bufnr then
        return bufnr, 0, 0
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    return bufnr, cursor[1] - 1, cursor[2], winid
end

local function citation_argument_context(bufnr, row, col)
    local before = coordinates.line_before_cursor(bufnr, row, col)
    if
        not (
            before:match("#cite%s*%([^%)]*$") ~= nil
            or before:match("cite%s*%([^%)]*$") ~= nil
        )
    then
        local line = coordinates.line_text(bufnr, row)
        if line:sub(col + 1, col + 1) == "(" then
            before = line:sub(1, col + 1)
        end
    end
    return before:match("#cite%s*%([^%)]*$") ~= nil
        or before:match("cite%s*%([^%)]*$") ~= nil
end

local function code_context(bufnr, row, col, opts)
    if opts.context == "code" then
        return true
    end
    if opts.context == "markup" then
        return false
    end

    local before = coordinates.line_before_cursor(bufnr, row, col)
    if before:match("^%s*#") then
        return true
    end

    local ok, context = pcall(require, "typst.completion.context")
    local kind_ok, kind = false, nil
    if ok then
        kind_ok, kind = pcall(context.kind, bufnr, { row = row, col = col })
    end
    if kind_ok and kind and kind ~= "markup" then
        return true
    end

    return false
end

local function citation_target_from_item(project, item)
    local source = item and item.source or {}
    if not source.path then
        return nil
    end

    return {
        kind = "citation",
        name = item.name,
        key = item.name,
        path = source.path,
        lnum = source.lnum or 1,
        col = source.col or 1,
        project = project,
        source = source,
        fields = item.fields,
        item = item,
    }
end

local function resolve_citation(opts)
    opts = opts or {}
    local project = project_context.resolve(opts)
    local key = opts.key or opts.name
    if opts.path and key then
        return {
            kind = "citation",
            name = key,
            key = key,
            path = opts.path,
            lnum = opts.lnum,
            col = opts.col,
            project = project,
            fields = opts.fields,
        }
    end

    if project and key then
        local collected = index.collect({ project = project }) or {}
        for _, item in ipairs(collected.citations or {}) do
            if item.name == key then
                return citation_target_from_item(project, item)
            end
        end
    end
    if key then
        return nil
    end

    local ok, follow = pcall(require, "typst.navigation.follow")
    local target = ok
            and follow.resolve({
                bufnr = opts.bufnr,
                cursor = opts.cursor,
                open = false,
                semantic = false,
            })
        or nil
    if type(target) == "table" and target.kind == "citation" then
        target.project = target.project or project
        target.key = target.key or target.name
        return target
    end
end

local function with_resolved_target(opts)
    opts = opts or {}
    local target = resolve_citation(opts)
    if not target then
        return opts, nil
    end

    return vim.tbl_extend("force", opts, {
        path = opts.path or target.path,
        key = opts.key or opts.name or target.key or target.name,
        name = opts.name or opts.key or target.name or target.key,
        lnum = opts.lnum or target.lnum,
        col = opts.col or target.col,
        fields = opts.fields or target.fields,
        project = opts.project or target.project,
    }),
        target
end

local function search_text_for(item, fields)
    local pieces = { item.name, item.label, item.detail }
    for _, name in ipairs(searchable_fields) do
        pieces[#pieces + 1] = fields and fields[name]
    end
    return table
        .concat(
            vim.tbl_filter(function(value)
                return type(value) == "string" and value ~= ""
            end, pieces),
            "\n"
        )
        :lower()
end

--- Return the citation text appropriate for the current Typst context.
---@param key string Bibliography key to insert.
---@param opts? table Insert options; `form` overrides automatic context detection.
---@return string text Typst citation syntax for the requested key.
function M.insert_text(key, opts)
    opts = opts or {}
    key = tostring(key or "")
    local form = opts.form
        or opts.citation_form
        or opts.bibliography_form
        or opts.insert_form

    if form == "function" or form == "cite" then
        return ("#cite(<%s>)"):format(key)
    end
    if form == "label" or form == "raw" or form == "argument" then
        return ("<%s>"):format(key)
    end
    if form == "markup" or form == "shorthand" then
        return "@" .. key
    end

    local bufnr, row, col = current_cursor(opts)
    if citation_argument_context(bufnr, row, col) then
        return ("<%s>"):format(key)
    end
    if code_context(bufnr, row, col, opts) then
        return ("#cite(<%s>)"):format(key)
    end
    return "@" .. key
end

--- Search project bibliography entries by key and common citation metadata.
---@param opts? table Search options with project/buffer overrides and optional `query`.
---@return table[] items Matching citation records with preview and insert text.
function M.search(opts)
    opts = opts or {}
    local project = project_context.resolve(opts)
    if not project then
        return {}
    end

    local query = vim.trim(tostring(opts.query or opts.key or opts.name or ""))
        :lower()
    local collected = index.collect({ project = project }) or {}
    local results = {}
    for _, item in ipairs(collected.citations or {}) do
        local source = item.source or {}
        local fields = item.fields
        if source.path and item.name then
            fields = vim.tbl_extend(
                "force",
                fields or {},
                M.expanded_fields({ path = source.path, key = item.name })
            )
        end

        if
            query == "" or search_text_for(item, fields):find(query, 1, true)
        then
            local preview = M.preview({
                path = source.path,
                key = item.name,
                fields = fields,
            })
            results[#results + 1] = {
                kind = "citation",
                name = item.name,
                key = item.name,
                path = source.path,
                lnum = source.lnum or 1,
                col = source.col or 1,
                source = source,
                fields = fields,
                project = project,
                item = item,
                preview = preview.text,
                insert_text = M.insert_text(item.name, opts),
            }
        end
    end

    table.sort(results, function(a, b)
        return a.key < b.key
    end)
    return results
end

--- Build a short human-readable citation preview from bibliography fields.
---@param opts table Entry lookup options or a table containing precomputed `fields`.
---@return table result Preview status, text, source key/path, and fields.
function M.preview(opts)
    opts = opts or {}
    opts = with_resolved_target(opts)
    local fields = opts.fields or M.expanded_fields(opts)
    local pieces = {}

    local author = field(fields, { "author", "editor" })
    local year = first_year(fields)
    local title = field(fields, { "title" })
    local venue = field(fields, {
        "journal",
        "journaltitle",
        "booktitle",
        "publisher",
        "organization",
        "location",
    })
    if author then
        pieces[#pieces + 1] = year and ("%s (%s)"):format(author, year)
            or author
    elseif year then
        pieces[#pieces + 1] = year
    end
    if title then
        pieces[#pieces + 1] = title
    end
    if venue then
        pieces[#pieces + 1] = venue
    end

    local text = table.concat(pieces, ". ")
    if text ~= "" and not text:match("[%.!?]$") then
        text = text .. "."
    end

    return {
        ok = text ~= "",
        key = opts.key or opts.name,
        path = opts.path,
        text = text,
        fields = fields,
    }
end

local function clean_path_component(value)
    value = tostring(value or "")
    value = value:gsub('[/\\:%*%?"<>|]', "-")
    value = value:gsub("%s+", " ")
    return vim.trim(value)
end

local function pattern_path(pattern, entry)
    return (pattern or ""):gsub("{([%w_%-%.]+)}", function(name)
        if name == "key" then
            return clean_path_component(entry.key)
        end
        return clean_path_component(entry.fields[name] or "")
    end)
end

local function candidate_pdf_from_field(value)
    if type(value) ~= "string" or value:match("^https?://") then
        return nil
    end
    return value:match("([^:;|]+%.pdf)")
        or value:match("([^:;|]+%.PDF)")
        or (value:match("%.pdf$") and value)
        or (value:match("%.PDF$") and value)
end

--- Resolve an attachment PDF for a bibliography entry.
---@param opts? table Attachment options; requires bibliography path and key/name.
---@return table result Attachment resolution result or failure payload.
function M.attachment(opts)
    opts = opts or {}
    opts = with_resolved_target(opts)
    local path = opts.path
    local key = opts.key or opts.name
    if not path or not key then
        return { ok = false, reason = "missing_target" }
    end

    local entry = entry_for(path, key, opts.lnum)
    if not entry then
        return { ok = false, reason = "missing_entry", path = path, key = key }
    end

    entry = vim.deepcopy(entry)
    entry.fields = M.expanded_fields({ path = path, key = key })
    local cfg = config.unsafe_get().bibliography or {}
    local base = opts.base or util.dirname(path)
    local checked = {}

    -- Field references win over filename patterns because bibliography managers
    -- often store the authoritative PDF path in a file/local-url field. Both
    -- forms resolve relative to the bibliography file unless a caller overrides
    -- the base.
    for _, name in ipairs(opts.fields or cfg.attachment_fields or {}) do
        local candidate = candidate_pdf_from_field(entry.fields[name])
        if candidate then
            local resolved = util.resolve_path(vim.trim(candidate), base)
            checked[#checked + 1] = resolved
            if util.readable(resolved) then
                return {
                    ok = true,
                    path = resolved,
                    key = key,
                    source = ("field:%s"):format(name),
                    checked = checked,
                }
            end
        end
    end

    for _, pattern in ipairs(opts.patterns or cfg.attachment_paths or {}) do
        local candidate = pattern_path(pattern, entry)
        if candidate ~= "" then
            local resolved = util.resolve_path(candidate, base)
            checked[#checked + 1] = resolved
            if util.readable(resolved) then
                return {
                    ok = true,
                    path = resolved,
                    key = key,
                    source = ("pattern:%s"):format(pattern),
                    checked = checked,
                }
            end
        end
    end

    return {
        ok = false,
        reason = "not_found",
        key = key,
        path = path,
        checked = checked,
    }
end

--- Resolve local PDF attachments for matching bibliography entries.
---@param opts? table Attachment lookup options; accepts key/query/project overrides.
---@return table result Attachment list and lookup status.
function M.attachments(opts)
    opts = opts or {}
    local query = vim.trim(tostring(opts.query or ""))
    local target = query == "" and resolve_citation(opts) or nil
    local results = {}
    if target then
        local attachment = M.attachment(vim.tbl_extend("force", opts, {
            path = target.path,
            key = target.key or target.name,
        }))
        if attachment.ok then
            results[#results + 1] = attachment
        end
    else
        for _, item in ipairs(M.search(opts)) do
            local attachment = M.attachment(vim.tbl_extend("force", opts, {
                path = item.path,
                key = item.key,
            }))
            if attachment.ok then
                attachment.preview = item.preview
                results[#results + 1] = attachment
            end
        end
    end

    return {
        ok = #results > 0,
        reason = #results > 0 and nil or "not_found",
        attachments = results,
        count = #results,
    }
end

--- Open or resolve the bibliography entry for a citation key.
---@param opts? table Open options; accepts key/path or cursor context.
---@return table result Open status and resolved target.
function M.open(opts)
    opts = opts or {}
    local target = resolve_citation(opts)
    if not target or not target.path then
        return { ok = false, reason = "missing_target" }
    end

    if opts.open == false then
        return { ok = true, target = target }
    end

    util.edit_existing_or_path(target.path)
    if target.lnum then
        local line_count = vim.api.nvim_buf_line_count(0)
        local lnum = math.min(math.max(target.lnum, 1), line_count)
        local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
            or ""
        local col = math.min(math.max((target.col or 1) - 1, 0), #line)
        vim.api.nvim_win_set_cursor(0, { lnum, col })
    end

    return { ok = true, target = target }
end

--- Insert a citation key at the cursor using Typst-aware syntax.
---@param opts table Insert options containing a key/name or search query.
---@return table result Insert status and inserted text.
function M.insert(opts)
    opts = opts or {}
    local key = opts.key or opts.name
    if not key then
        local matches = M.search(opts)
        if #matches == 1 then
            key = matches[1].key
        else
            return {
                ok = false,
                reason = #matches == 0 and "not_found" or "ambiguous",
                matches = matches,
            }
        end
    end

    local text = M.insert_text(key, opts)
    if opts.apply == false then
        return { ok = true, key = key, text = text }
    end

    local bufnr, row, col, winid = current_cursor(opts)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        return {
            ok = false,
            reason = "invalid_buffer",
            key = key,
            text = text,
            bufnr = bufnr,
        }
    end
    if vim.bo[bufnr].modifiable == false then
        return {
            ok = false,
            reason = "buffer_not_modifiable",
            key = key,
            text = text,
            bufnr = bufnr,
        }
    end
    if vim.bo[bufnr].readonly and opts.allow_readonly ~= true then
        return {
            ok = false,
            reason = "buffer_readonly",
            key = key,
            text = text,
            bufnr = bufnr,
        }
    end

    local inserted, insert_err =
        pcall(vim.api.nvim_buf_set_text, bufnr, row, col, row, col, { text })
    if not inserted then
        return {
            ok = false,
            reason = "insert_failed",
            key = key,
            text = text,
            bufnr = bufnr,
            error = tostring(insert_err),
        }
    end
    if winid then
        pcall(vim.api.nvim_win_set_cursor, winid, { row + 1, col + #text })
    end
    return { ok = true, key = key, text = text }
end

local function valid_key(key)
    return type(key) == "string" and key:match("^[%w_.:/%-]+$") ~= nil
end

local function validate_rename_keys(old_key, new_key)
    old_key = type(old_key) == "string" and vim.trim(old_key) or old_key
    new_key = type(new_key) == "string" and vim.trim(new_key) or new_key
    if not valid_key(old_key) or not valid_key(new_key) then
        return nil,
            nil,
            {
                ok = false,
                reason = "invalid_key",
                old_key = old_key,
                new_key = new_key,
            }
    end
    return old_key, new_key
end

local function add_edit(edits, seen, kind, source, expected, replacement)
    if
        not source
        or not source.path
        or not source.lnum
        or not source.col
        or not expected
        or not replacement
    then
        return
    end

    local key = table.concat({
        kind,
        util.path_key(source.path),
        source.lnum,
        source.col,
        expected,
    }, "\n")
    if seen[key] then
        return
    end
    seen[key] = true

    local start_col = source.col - 1
    edits[#edits + 1] = {
        kind = kind,
        path = source.path,
        row = source.lnum - 1,
        start_col = start_col,
        end_col = start_col + #expected,
        expected = expected,
        replacement = replacement,
    }
end

local function source_for_entry(path, entry)
    return {
        path = path,
        lnum = entry.lnum or 1,
        col = entry.col or 1,
    }
end

local function project_bibliography_paths(project, collected)
    local paths = {}
    local seen = {}
    local function add(path)
        if path and not seen[util.path_key(path)] then
            seen[util.path_key(path)] = true
            paths[#paths + 1] = path
        end
    end

    for path in pairs((collected or {}).bibliography_paths or {}) do
        add(path)
    end
    if #paths == 0 and project and project.main then
        -- Older or partial index data may know where citations were found even
        -- when it did not record the bibliography declarations. Use citation
        -- source files as a narrow fallback instead of scanning the workspace.
        for _, item in ipairs((collected or {}).citations or {}) do
            local source = item.source or {}
            if source.path then
                add(source.path)
            end
        end
    end
    table.sort(paths)
    return paths
end

local function bibliography_paths(project, collected, opts)
    if opts.path then
        return { opts.path }
    end
    return project_bibliography_paths(project, collected)
end

local function collision_bibliography_paths(project, collected, opts)
    local paths = project_bibliography_paths(project, collected)
    if opts.path then
        local key = util.path_key(opts.path)
        local found = false
        for _, path in ipairs(paths) do
            if util.path_key(path) == key then
                found = true
                break
            end
        end
        if not found then
            paths[#paths + 1] = opts.path
            table.sort(paths)
        end
    end
    return paths
end

--- Plan a bibliography key rename across source files and Typst citations.
---@param opts table Rename options containing old/new key data and project context.
---@return table plan File edits, duplicate status, and target entry metadata.
function M.rename_plan(opts)
    opts = opts or {}
    local old_key = opts.old_key or opts.key or opts.name
    local new_key = opts.new_key
    local valid_old, valid_new, invalid = validate_rename_keys(old_key, new_key)
    if not valid_old then
        return invalid
            or {
                ok = false,
                reason = "invalid_key",
                old_key = old_key,
                new_key = new_key,
            }
    end
    old_key = valid_old
    new_key = valid_new
    local project = project_context.resolve(opts)
    local collected = project and index.collect({ project = project }) or {}
    local edits = {}
    local seen = {}
    local entry_path = opts.path
    local existing = false

    -- Rename planning spans both bibliography files and Typst citation syntax.
    -- Build all edits before applying so duplicate-key checks can fail without
    -- partially modifying project files.
    for _, path in
        ipairs(collision_bibliography_paths(project, collected, opts))
    do
        for _, entry in ipairs(entries_for_path(path)) do
            if entry.key == new_key then
                existing = true
            end
        end
    end

    for _, path in ipairs(bibliography_paths(project, collected, opts)) do
        for _, entry in ipairs(entries_for_path(path)) do
            if entry.key == old_key then
                entry_path = entry_path or path
                add_edit(
                    edits,
                    seen,
                    "bibliography_entry",
                    source_for_entry(path, entry),
                    old_key,
                    new_key
                )
            end
        end
    end

    for _, reference in ipairs((collected or {}).references or {}) do
        local name = reference.reference_target_name or reference.name
        if
            name == old_key
            and (
                reference.reference_target == "citation"
                or reference.reference_style == "cite"
            )
        then
            if reference.reference_style == "cite" then
                add_edit(
                    edits,
                    seen,
                    "citation_reference",
                    reference.source,
                    "<" .. old_key .. ">",
                    "<" .. new_key .. ">"
                )
            else
                add_edit(
                    edits,
                    seen,
                    "citation_reference",
                    reference.source,
                    "@" .. old_key,
                    "@" .. new_key
                )
            end
        end
    end

    table.sort(edits, function(a, b)
        if util.same_path(a.path, b.path) then
            if a.row == b.row then
                return a.start_col > b.start_col
            end
            return a.row > b.row
        end
        return a.path < b.path
    end)
    return {
        kind = "bibliography_key_rename",
        key = old_key,
        old_key = old_key,
        new_key = new_key,
        path = entry_path,
        duplicate = existing,
        edits = edits,
    }
end

--- Apply a bibliography key rename plan.
---@param opts table Rename options containing old/new key data and project context.
---@return table result Rename status, plan data, and file-application result.
function M.rename_key(opts)
    opts = opts or {}
    local old_key = opts.old_key or opts.key or opts.name
    local new_key = opts.new_key
    local valid_old, valid_new, invalid = validate_rename_keys(old_key, new_key)
    if not valid_old then
        return invalid
            or {
                ok = false,
                reason = "invalid_key",
                old_key = old_key,
                new_key = new_key,
            }
    end
    old_key = valid_old
    new_key = valid_new
    if old_key == new_key then
        return {
            ok = false,
            reason = "unchanged_key",
            old_key = old_key,
            new_key = new_key,
        }
    end

    local plan = M.rename_plan(vim.tbl_extend("force", opts, {
        old_key = old_key,
        new_key = new_key,
    }))
    if plan.duplicate and opts.allow_existing ~= true then
        plan.ok = false
        plan.reason = "duplicate_key"
        return plan
    end
    if opts.apply == false then
        plan.ok = #plan.edits > 0
        return plan
    end

    local by_path = {}
    for _, edit in ipairs(plan.edits) do
        local path_key = util.path_key(edit.path)
        by_path[path_key] = by_path[path_key]
            or {
                path = edit.path,
                edits = {},
            }
        by_path[path_key].edits[#by_path[path_key].edits + 1] = edit
    end

    local prepared = {}
    local failed = {}
    for _, group in pairs(by_path) do
        table.sort(group.edits, function(a, b)
            if a.row == b.row then
                return a.start_col > b.start_col
            end
            return a.row > b.row
        end)
        local prepared_file, reason =
            file_edits.prepare(group.path, group.edits)
        if prepared_file then
            prepared_file.path = prepared_file.path or group.path
            prepared[#prepared + 1] = prepared_file
        else
            failed[#failed + 1] = {
                path = group.path,
                reason = reason or "failed",
            }
        end
    end

    if #failed > 0 then
        plan.ok = false
        plan.reason = failed[1].reason
        plan.failed_files = failed
        return plan
    end

    local applied, apply_error = file_edits.apply(prepared)
    if not applied then
        plan.ok = false
        plan.reason = (apply_error and apply_error.reason) or "apply_failed"
        plan.failed_files = apply_error and { apply_error } or nil
        plan.recovery = apply_error and apply_error.recovery or nil
        return plan
    end

    local files = {}
    for _, prepared_file in ipairs(prepared) do
        files[#files + 1] = prepared_file.path
    end
    table.sort(files)
    -- The parser cache keys loaded buffers and file mtimes. After applying a
    -- multi-file rename, clear it so follow-up status/preview commands cannot
    -- reuse entries parsed before the edits landed.
    parser.reset()

    plan.ok = #plan.edits > 0
    plan.files = files
    return plan
end

--- Summarize bibliography health for the current or supplied project.
---@param opts? table Status options, including project/buffer overrides.
---@return table result Bibliography status summary.
function M.status(opts)
    opts = opts or {}
    local project = project_context.resolve(opts)
    if not project then
        return { ok = false, reason = "no_project" }
    end

    local collected = index.collect({ project = project }) or {}
    local entries_by_key = {}
    local entry_count = 0
    local bibliography_path_count = 0
    for _, path in ipairs(bibliography_paths(project, collected, opts)) do
        bibliography_path_count = bibliography_path_count + 1
        for _, entry in ipairs(entries_for_path(path)) do
            if entry.key then
                entry_count = entry_count + 1
                entries_by_key[entry.key] = entries_by_key[entry.key] or {}
                entries_by_key[entry.key][#entries_by_key[entry.key] + 1] =
                    entry
            end
        end
    end

    local used = {}
    local missing = {}
    local missing_seen = {}
    for _, reference in ipairs(collected.references or {}) do
        local name = reference.reference_target_name or reference.name
        if
            name
            and (
                reference.reference_target == "citation"
                or reference.reference_style == "cite"
            )
        then
            used[name] = true
            if not entries_by_key[name] and not missing_seen[name] then
                missing_seen[name] = true
                missing[#missing + 1] = name
            end
        end
    end

    local duplicate_count = 0
    local unused_count = 0
    for key, entries in pairs(entries_by_key) do
        if #entries > 1 then
            duplicate_count = duplicate_count + (#entries - 1)
        end
        if not used[key] then
            unused_count = unused_count + 1
        end
    end

    table.sort(missing)
    return {
        ok = true,
        project = project,
        paths = bibliography_path_count,
        entries = entry_count,
        used = vim.tbl_count(used),
        missing = missing,
        missing_count = #missing,
        duplicates = duplicate_count,
        unused = unused_count,
    }
end

return M
