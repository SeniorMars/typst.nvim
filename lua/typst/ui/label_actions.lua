local index = require("typst.index")
local project_context = require("typst.project.context")
local label_rename = require("typst.ui.label_rename")
local util = require("typst.core.util")

local M = {}

local function resolve_project(bufnr)
    return project_context.resolve({ bufnr = bufnr }, { create = true })
end

local function line_at(bufnr, row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

function M.project_references(bufnr, name)
    local project = resolve_project(bufnr)
    local collected = project and index.collect({ project = project }) or nil
    local refs = {}
    for _, ref in ipairs(collected and collected.references or {}) do
        if ref.name == name or ref.name:gsub("[%.,;:]+$", "") == name then
            refs[#refs + 1] = ref
        end
    end
    return refs, project
end

function M.source_to_qf_item(source, text)
    if not source or not source.path then
        return nil
    end

    return {
        filename = source.path,
        lnum = source.lnum or 1,
        col = source.col or 1,
        text = text,
    }
end

function M.source_line(source)
    if not source or not source.path then
        return nil
    end

    local bufnr = util.loaded_buffer_for_path(source.path)
    if bufnr then
        return line_at(bufnr, (source.lnum or 1) - 1)
    end

    if vim.fn.filereadable(source.path) ~= 1 then
        return nil
    end

    local ok, lines = pcall(vim.fn.readfile, source.path, "", source.lnum or 1)
    if ok and lines then
        return lines[source.lnum or 1]
    end
end

function M.open_quickfix(title, items, opts)
    opts = opts or {}
    if opts.open == false then
        return items
    end

    vim.fn.setqflist({}, "r", {
        title = title,
        items = items,
    })
    if #items > 0 then
        vim.cmd("copen")
    end
    return items
end

function M.add(actions, target, bufnr, handlers)
    if not target or target.kind ~= "label" or not target.name then
        return
    end

    handlers = handlers or {}
    local add_action = handlers.add_action
        or function(list, action)
            list[#list + 1] = action
        end
    ---@type fun(message:string, level?:integer)
    local notify = handlers.notify or function(_, _) end

    add_action(actions, {
        id = "copy_label",
        title = "Copy label name",
        kind = "copy",
        target = target,
        run = function()
            vim.fn.setreg('"', target.name)
            notify(("Copied %s"):format(target.name))
            return target.name
        end,
    })

    add_action(actions, {
        id = "label_references",
        title = ("List references to %s"):format(target.name),
        kind = "reference",
        target = target,
        run = function(run_opts)
            local refs = M.project_references(bufnr, target.name)
            local items = {}
            for _, ref in ipairs(refs) do
                local item =
                    M.source_to_qf_item(ref.source, ("@%s"):format(ref.name))
                if item then
                    items[#items + 1] = item
                end
            end
            return M.open_quickfix(
                ("Typst references: %s"):format(target.name),
                items,
                run_opts or {}
            )
        end,
    })

    add_action(actions, {
        id = "label_rename",
        title = ("Rename label %s"):format(target.name),
        kind = "rename",
        target = target,
        run = function(run_opts)
            run_opts = run_opts or {}
            if run_opts.new_name then
                return label_rename.rename(
                    bufnr,
                    target,
                    run_opts.new_name,
                    run_opts,
                    notify
                )
            end

            local plan = label_rename.plan(bufnr, target, target.name)
            if run_opts.open == false then
                return plan
            end

            vim.ui.input({
                prompt = "Rename Typst label: ",
                default = target.name,
            }, function(new_name)
                if new_name then
                    label_rename.rename(
                        bufnr,
                        target,
                        new_name,
                        vim.tbl_extend("force", run_opts, {
                            callback = run_opts.callback or function() end,
                        }),
                        notify
                    )
                end
            end)
            return plan
        end,
    })
end

return M
