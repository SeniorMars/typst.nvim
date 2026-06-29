local command = require("typst.ui.commands.util")
local complete = require("typst.ui.commands.complete")
local open_helper = require("typst.core.open")

local M = {}

local create = command.create
local opts = command.opts

local function split_args(args)
    local parts = {}
    for part in tostring((args and args.args) or ""):gmatch("%S+") do
        parts[#parts + 1] = part
    end
    return parts
end

local function notify_result(notify, label, result)
    if result and result.ok then
        notify(label)
        return
    end
    notify(
        ("%s failed: %s"):format(label, (result and result.reason) or "unknown"),
        vim.log.levels.WARN
    )
end

local function set_attachment_quickfix(result)
    local items = {}
    for _, attachment in ipairs((result and result.attachments) or {}) do
        items[#items + 1] = {
            filename = attachment.path,
            lnum = 1,
            col = 1,
            text = attachment.preview
                    and ("%s — %s"):format(attachment.key, attachment.preview)
                or attachment.key,
        }
    end

    vim.fn.setqflist({}, " ", {
        title = "typst.nvim bibliography attachments",
        items = items,
    })
end

local function open_attachment(path)
    local object = open_helper.ui_open(path)
    if object then
        return true
    end
    return false
end

--- Register bibliography and citation user commands.
---@param ctx table Runtime command context with public API and notify sink.
function M.register(ctx)
    local api = ctx.api
    local notify = ctx.notify

    create("TypstCitationInsert", function(args)
        local query = vim.trim(args.args or "")
        local key = nil
        if query ~= "" then
            for _, item in ipairs(api.bibliography.search({ query = query })) do
                if item.key == query then
                    key = query
                    break
                end
            end

            if key then
                local result = api.bibliography.insert({
                    key = key,
                    insert_form = "auto",
                })
                if result and result.ok then
                    return
                end
            end
        end

        api.picker.open({
            kind = "bibliography",
            query = query ~= "" and query or nil,
            insert_form = "auto",
            action = function(item)
                return api.bibliography.insert({
                    key = item.citation_key or item.name,
                    insert_form = "auto",
                })
            end,
        })
    end, opts("Insert a Typst citation", "?", complete.citation))

    create("TypstCitationSearch", function(args)
        api.picker.open({
            kind = "bibliography",
            query = vim.trim(args.args or ""),
            insert_form = "auto",
        })
    end, opts("Search bibliography entries", "*", complete.citation))

    create("TypstCitationOpen", function(args)
        local key = vim.trim(args.args or "")
        local result = api.bibliography.open({
            key = key ~= "" and key or nil,
        })
        notify_result(notify, "Opened citation", result)
    end, opts("Open a bibliography entry", "?", complete.citation))

    create("TypstCitationPreview", function(args)
        local key = vim.trim(args.args or "")
        local result = api.bibliography.preview({
            key = key ~= "" and key or nil,
        })
        if result and result.ok then
            notify(result.text)
        else
            notify(
                ("Citation preview failed: %s"):format(
                    (result and result.reason) or "missing_target"
                ),
                vim.log.levels.WARN
            )
        end
    end, opts("Preview a bibliography entry", "?", complete.citation))

    create("TypstCitationRename", function(args)
        local parts = split_args(args)
        local call_opts = {}
        if #parts >= 2 then
            call_opts.old_key = parts[1]
            call_opts.new_key = parts[2]
        elseif #parts == 1 then
            local target = api.bibliography.open({ open = false })
            call_opts.old_key = target
                and target.target
                and (target.target.key or target.target.name)
            call_opts.new_key = parts[1]
        else
            notify("Citation rename needs a new key", vim.log.levels.WARN)
            return
        end

        local result = api.bibliography.rename_key(call_opts)
        if result and result.ok then
            notify(
                ("Renamed citation `%s` to `%s`"):format(
                    result.old_key,
                    result.new_key
                )
            )
        else
            notify(
                ("Citation rename failed: %s"):format(
                    (result and result.reason) or "unknown"
                ),
                vim.log.levels.WARN
            )
        end
    end, opts("Rename a citation key", "+", complete.citation))

    create("TypstBibliographyStatus", function()
        local result = api.bibliography.status()
        if result and result.ok then
            notify(
                ("Bibliography: %d entries, %d used, %d unused, %d missing, %d duplicate"):format(
                    result.entries,
                    result.used,
                    result.unused,
                    result.missing_count,
                    result.duplicates
                )
            )
        else
            notify(
                ("Bibliography status failed: %s"):format(
                    (result and result.reason) or "unknown"
                ),
                vim.log.levels.WARN
            )
        end
    end, opts("Summarize project bibliography status"))

    create(
        "TypstBibliographyDiagnostics",
        function(args)
            local result = api.bibliography.diagnostics({
                quickfix = true,
                open = args.bang,
            })
            notify(
                ("Bibliography diagnostics: %d item%s"):format(
                    result.diagnostics,
                    result.diagnostics == 1 and "" or "s"
                )
            )
        end,
        vim.tbl_extend(
            "force",
            opts("Check bibliography keys in the current Typst project"),
            {
                bang = true,
            }
        )
    )

    create(
        "TypstBibliographyAttachments",
        function(args)
            local query = vim.trim(args.args or "")
            local result = api.bibliography.attachments({
                key = query ~= "" and query or nil,
                query = query ~= "" and query or nil,
            })
            set_attachment_quickfix(result)
            if result and result.count == 1 then
                open_attachment(result.attachments[1].path)
            elseif args.bang then
                vim.cmd.copen()
            end
            notify(
                ("Bibliography attachments: %d item%s"):format(
                    result and result.count or 0,
                    result and result.count == 1 and "" or "s"
                )
            )
        end,
        vim.tbl_extend(
            "force",
            opts("List local bibliography attachments", "*", complete.citation),
            {
                bang = true,
            }
        )
    )
end

return M
