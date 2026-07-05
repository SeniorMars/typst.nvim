local bibliography = require("typst.bibliography")

local M = {}

local function citation_fields(target)
    return bibliography.expanded_fields({
        path = target.path,
        key = target.name,
        lnum = target.lnum,
    })
end

local function doi_url(value)
    value = vim.trim(value or "")
    if value == "" then
        return nil
    end

    if value:match("^https?://") then
        local doi_path = value:match("^https?://[Dd][Oo][Ii]%.org/(.+)$")
            or value:match("^https?://[Dd][Xx]%.[Dd][Oo][Ii]%.org/(.+)$")
        if doi_path then
            value = doi_path
        else
            return value
        end
    else
        value = value:gsub("^[Dd][Oo][Ii]%s*:%s*", "")
        value = value:gsub("^[Dd][Oo][Ii]%.org/", "")
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end
    if value:match("^https?://") then
        return value
    end
    return "https://doi.org/" .. value
end

function M.add(actions, target, handlers)
    if not target or target.kind ~= "citation" then
        return
    end

    handlers = handlers or {}
    local add_action = handlers.add_action
        or function(list, action)
            list[#list + 1] = action
        end
    ---@type fun(message:string, level?:integer)
    local notify = handlers.notify or function(_, _) end
    local open_url = handlers.open_url
    local open_file_at = handlers.open_file_at

    add_action(actions, {
        id = "citation_entry",
        title = "Open bibliography entry",
        kind = "citation",
        target = target,
        run = function(run_opts)
            return open_file_at(
                target.path,
                target.lnum,
                target.col,
                run_opts or {}
            )
        end,
    })
    add_action(actions, {
        id = "copy_citation_key",
        title = "Copy citation key",
        kind = "copy",
        target = target,
        run = function()
            vim.fn.setreg('"', target.name or "")
            notify(("Copied %s"):format(target.name or ""))
            return target.name
        end,
    })
    add_action(actions, {
        id = "citation_preview",
        title = "Preview citation",
        kind = "preview",
        target = target,
        run = function(run_opts)
            run_opts = run_opts or {}
            local preview = bibliography.preview({
                path = target.path,
                key = target.name,
                lnum = target.lnum,
            })
            if preview.ok and run_opts.open ~= false then
                notify(preview.text)
            end
            return preview
        end,
    })
    add_action(actions, {
        id = "citation_rename",
        title = ("Rename citation key %s"):format(target.name or ""),
        kind = "rename",
        target = target,
        run = function(run_opts)
            run_opts = run_opts or {}
            if run_opts.new_name then
                return bibliography.rename_key({
                    bufnr = run_opts.bufnr,
                    path = target.path,
                    old_key = target.name,
                    new_key = run_opts.new_name,
                    apply = run_opts.apply,
                    allow_existing = run_opts.allow_existing,
                })
            end

            local plan = bibliography.rename_plan({
                bufnr = run_opts.bufnr,
                path = target.path,
                old_key = target.name,
                new_key = target.name,
            })
            if run_opts.open == false then
                return plan
            end

            vim.ui.input({
                prompt = "Rename Typst citation key: ",
                default = target.name,
            }, function(new_name)
                if new_name then
                    bibliography.rename_key({
                        bufnr = run_opts.bufnr,
                        path = target.path,
                        old_key = target.name,
                        new_key = new_name,
                    })
                end
            end)
            return plan
        end,
    })
    local fields = citation_fields(target)
    local url = fields.url
    if url then
        add_action(actions, {
            id = "citation_url",
            title = "Open citation URL",
            kind = "url",
            target = vim.tbl_extend("force", target, { url = url }),
            run = function(run_opts)
                return open_url(url, run_opts or {})
            end,
        })
    end

    local doi = doi_url(fields.doi)
    if doi then
        add_action(actions, {
            id = "citation_doi",
            title = "Open citation DOI",
            kind = "url",
            target = vim.tbl_extend("force", target, { url = doi }),
            run = function(run_opts)
                return open_url(doi, run_opts or {})
            end,
        })
    end

    local attachment = bibliography.attachment({
        path = target.path,
        key = target.name,
        lnum = target.lnum,
    })
    if attachment.ok then
        add_action(actions, {
            id = "citation_pdf",
            title = "Open citation PDF",
            kind = "path",
            target = vim.tbl_extend(
                "force",
                target,
                { path = attachment.path }
            ),
            run = function(run_opts)
                return open_file_at(attachment.path, nil, nil, run_opts or {})
            end,
        })
    end
end

return M
