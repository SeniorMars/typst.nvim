local core = require("typst.ui.context_menu_core")
local open_helper = require("typst.core.open")

local M = {}

local function image_info(target)
    if not target or target.kind ~= "path" or type(target.path) ~= "string" then
        return nil
    end

    local ext = (target.path:match("%.([%w]+)$") or ""):lower()
    if
        not ({
            svg = true,
            png = true,
            jpg = true,
            jpeg = true,
            gif = true,
            webp = true,
        })[ext]
    then
        return nil
    end

    return {
        kind = "image",
        path = target.path,
        source = target.word,
        extension = ext,
        readable = vim.fn.filereadable(target.path) == 1,
        provider = target.provider or "syntax",
    }
end

function M.add_path_actions(actions, target)
    if not target or target.kind ~= "path" or type(target.path) ~= "string" then
        return
    end

    core.add_action(actions, {
        id = "path_reveal",
        title = "Reveal file",
        kind = "path",
        target = target,
        run = function(run_opts)
            return core.reveal_file(target.path, run_opts or {})
        end,
    })
end

function M.add_image_actions(actions, target)
    local info = image_info(target)
    if not info then
        return
    end

    core.add_action(actions, {
        id = "image_open",
        title = "Open image file",
        kind = "image",
        target = target,
        run = function(run_opts)
            return core.open_file_at(info.path, nil, nil, run_opts or {})
        end,
    })

    core.add_action(actions, {
        id = "image_preview",
        title = "Preview image",
        kind = "image",
        target = target,
        run = function(run_opts)
            run_opts = run_opts or {}
            if run_opts.open == false then
                return vim.deepcopy(info)
            end

            if vim.ui and vim.ui.open then
                local object = open_helper.ui_open(info.path)
                if not object then
                    core.open_file_at(info.path, nil, nil, run_opts)
                end
            else
                core.open_file_at(info.path, nil, nil, run_opts)
            end
            return vim.deepcopy(info)
        end,
    })
end

return M
