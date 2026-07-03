local index = require("typst.index")
local project_context = require("typst.project.context")
local tinymist = require("typst.integrations.tinymist")
local file_edits = require("typst.ui.label_rename_files")
local util = require("typst.core.util")

local M = {}

-- Label rename orchestration.
--
-- Prefer Tinymist semantic rename when a callback is available, then fall back
-- to the static project index. `semantic = true` disables fallback so callers
-- can distinguish LSP failure from syntax-only edits.

---@class TypstLabelRenamePlan
---@field ok boolean|nil
---@field kind string
---@field provider string
---@field semantic boolean|nil
---@field name string
---@field new_name string
---@field edits table[]|nil
---@field files string[]|nil
---@field reason string|nil

local function semantic_async_required(target, new_name)
    return {
        ok = false,
        kind = "label_rename",
        provider = "tinymist",
        semantic = true,
        reason = "async_required",
        message = "Tinymist semantic rename requires a callback",
        name = target.name,
        new_name = new_name,
        applied = false,
    }
end

local function resolve_project(bufnr)
    return project_context.resolve({ bufnr = bufnr }, { create = true })
end

local function valid_label_name(name)
    return type(name) == "string" and name:match("^[%w_.:/%-]+$") ~= nil
end

function M.plan(bufnr, target, new_name)
    local project = resolve_project(bufnr)
    local collected = project
            and index.collect({ bufnr = bufnr, project = project })
        or {}
    local edits = {}
    local seen = {}

    local function add_edit(item, opts)
        opts = opts or {}
        local source = item and item.source
        if
            not source
            or not source.path
            or not source.lnum
            or not source.col
        then
            return
        end

        local key = table.concat({
            opts.kind or "reference",
            util.path_key(source.path),
            source.lnum,
            source.col,
        }, "\n")
        if seen[key] then
            return
        end
        seen[key] = true

        local expected = opts.expected
        local replacement = opts.replacement
        local start_col = source.col - 1
        -- Carry expected text into file prep so stale index data cannot rewrite
        -- an unrelated label/reference at the same byte span.
        edits[#edits + 1] = {
            kind = opts.kind or "reference",
            path = source.path,
            row = source.lnum - 1,
            start_col = start_col,
            end_col = start_col + #expected,
            expected = expected,
            replacement = replacement,
        }
    end

    local function add_label(item)
        add_edit(item, {
            kind = "label",
            expected = "<" .. target.name .. ">",
            replacement = "<" .. new_name .. ">",
        })
    end

    local function add_reference(item)
        if item.reference_style == "function" then
            add_edit(item, {
                kind = "reference",
                expected = "<" .. target.name .. ">",
                replacement = "<" .. new_name .. ">",
            })
            return
        end

        add_edit(item, {
            kind = "reference",
            expected = "@" .. target.name,
            replacement = "@" .. new_name,
        })
    end

    for _, label in ipairs(collected.labels or {}) do
        if label.name == target.name then
            add_label(label)
        end
    end

    for _, ref in ipairs(collected.references or {}) do
        if
            ref.name == target.name
            or ref.name:gsub("[%.,;:]+$", "") == target.name
        then
            add_reference(ref)
        end
    end

    if #edits == 0 and target.path and target.lnum and target.col then
        add_label({
            source = {
                path = target.path,
                lnum = target.lnum,
                col = target.col,
            },
        })
    end

    -- Apply edits right-to-left within a line; otherwise an earlier replacement
    -- can shift the columns for another edit on the same line.
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
        kind = "label_rename",
        provider = "syntax",
        semantic = false,
        name = target.name,
        new_name = new_name,
        edits = edits,
    }
end

function M.rename(bufnr, target, new_name, opts, notify)
    opts = opts or {}
    notify = notify or function() end
    new_name = vim.trim(new_name or "")
    if new_name == "" or new_name == target.name then
        return nil
    end

    if not valid_label_name(new_name) then
        notify(
            ("Invalid Typst label name: %s"):format(new_name),
            vim.log.levels.ERROR
        )
        return {
            ok = false,
            reason = "invalid_name",
            name = target.name,
            new_name = new_name,
        }
    end

    if type(opts.callback) == "function" and opts.semantic ~= false then
        -- Tinymist rename is async. Without a callback we cannot wait and still
        -- preserve this API's return shape.
        return tinymist.rename(bufnr, new_name, {
            apply = opts.apply,
            position = opts.position,
            timeout_ms = opts.timeout_ms,
            callback = function(semantic)
                if semantic.ok then
                    opts.callback({
                        ok = true,
                        kind = "label_rename",
                        provider = "tinymist",
                        name = target.name,
                        new_name = new_name,
                        edit = semantic.edit,
                        applied = semantic.applied,
                    })
                    return
                end

                if opts.semantic == true then
                    opts.callback({
                        ok = false,
                        kind = "label_rename",
                        provider = "tinymist",
                        semantic = true,
                        reason = semantic.reason or "rename_failed",
                        message = semantic.message,
                        name = target.name,
                        new_name = new_name,
                        applied = false,
                    })
                    return
                end

                opts.callback(
                    M.rename(
                        bufnr,
                        target,
                        new_name,
                        vim.tbl_extend("force", opts, {
                            callback = nil,
                            semantic = false,
                        }),
                        notify
                    )
                )
            end,
        })
    elseif opts.semantic == true then
        return semantic_async_required(target, new_name)
    end

    local plan = M.plan(bufnr, target, new_name)
    local by_path = {}
    for _, edit in ipairs(plan.edits) do
        local key = util.path_key(edit.path)
        by_path[key] = by_path[key]
            or {
                path = edit.path,
                edits = {},
            }
        by_path[key].edits[#by_path[key].edits + 1] = edit
    end

    local changed_files = {}
    local prepared = {}
    local failed = {}
    for _, group in pairs(by_path) do
        local path = group.path
        local edits = group.edits
        table.sort(edits, function(a, b)
            if a.row == b.row then
                return a.start_col > b.start_col
            end
            return a.row > b.row
        end)
        local prepared_file, reason = file_edits.prepare(path, edits)
        if prepared_file then
            prepared_file.path = prepared_file.path or path
            prepared[#prepared + 1] = prepared_file
        else
            failed[#failed + 1] = {
                path = path,
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
    if applied then
        for _, prepared_file in ipairs(prepared) do
            changed_files[#changed_files + 1] = prepared_file.path
        end
    elseif apply_error then
        failed[#failed + 1] = apply_error
    end
    table.sort(changed_files)

    plan.ok = #plan.edits > 0 and #changed_files == #prepared
    plan.files = changed_files
    if #failed > 0 then
        plan.reason = failed[1].reason
        plan.failed_files = failed
    end
    if plan.ok and opts.notify ~= false then
        notify(("Renamed label %s to %s"):format(target.name, new_name))
    end
    return plan
end

return M
