local core = require("typst.ui.context_menu_core")
local edit_ts = require("typst.core.treesitter")
local transform = require("typst.edit.transform")

local M = {}

function M.add_heading_actions(actions, bufnr, pos)
    if
        not edit_ts.find_containing(bufnr, "heading", pos)
        and not core.line_at(bufnr, pos[1]):match("^%s*=+%s+")
    then
        return
    end

    core.add_action(actions, {
        id = "heading_promote",
        title = "Promote heading",
        kind = "heading",
        run = function(run_opts)
            return transform.promote_heading(
                core.transform_opts(bufnr, pos, run_opts)
            )
        end,
    })
    core.add_action(actions, {
        id = "heading_demote",
        title = "Demote heading",
        kind = "heading",
        run = function(run_opts)
            return transform.demote_heading(
                core.transform_opts(bufnr, pos, run_opts)
            )
        end,
    })
end

local function line_has_inline_equation(bufnr, pos)
    local line = core.line_at(bufnr, pos[1])
    local start_index = 1

    while true do
        local start_col = line:find("%$", start_index)
        if not start_col then
            return false
        end

        local end_col = line:find("%$", start_col + 1)
        if not end_col then
            return false
        end

        if pos[2] >= start_col - 1 and pos[2] < end_col then
            return true
        end

        start_index = end_col + 1
    end
end

local function line_has_math_equation_call(bufnr, pos)
    local line = core.line_at(bufnr, pos[1])
    local start_col = line:find("#?math%.equation%s*%(")
    if not start_col then
        return false
    end

    local end_col = line:find("%)%s*$", start_col) or #line
    return pos[2] >= start_col - 1 and pos[2] < end_col
end

local function select_transform_option(items, prompt, run_opts, apply)
    run_opts = run_opts or {}
    if run_opts.style then
        return apply(run_opts.style)
    end

    if run_opts.open == false then
        return vim.deepcopy(items)
    end

    vim.ui.select(items, { prompt = prompt }, apply)
    return items
end

function M.add_equation_actions(actions, bufnr, pos)
    local has_equation = edit_ts.find_containing(bufnr, "equation", pos)
    if not has_equation then
        has_equation = line_has_inline_equation(bufnr, pos)
    end

    local has_equation_call = false
    if not has_equation then
        local call = edit_ts.find_containing(bufnr, "function_call", pos)
        if call then
            local range = edit_ts.range(call)
            local text = table.concat(
                vim.api.nvim_buf_get_text(
                    bufnr,
                    range.start_row,
                    range.start_col,
                    range.end_row,
                    range.end_col,
                    {}
                ),
                "\n"
            )
            has_equation_call = text:match("^#?math%.equation%s*%(") ~= nil
        else
            has_equation_call = line_has_math_equation_call(bufnr, pos)
        end
    end

    if not has_equation and not has_equation_call then
        return
    end

    if has_equation then
        core.add_action(actions, {
            id = "equation_convert",
            title = "Convert equation style",
            kind = "equation",
            run = function(run_opts)
                return select_transform_option(
                    { "toggle", "inline", "block" },
                    "Typst equation style",
                    run_opts,
                    function(style)
                        if not style then
                            return nil
                        end
                        return transform.convert_equation(
                            style,
                            core.transform_opts(bufnr, pos, run_opts)
                        )
                    end
                )
            end,
        })
    end

    core.add_action(actions, {
        id = "equation_numbering",
        title = "Toggle equation numbering",
        kind = "equation",
        run = function(run_opts)
            return select_transform_option(
                { "toggle", "on", "off" },
                "Typst equation numbering",
                run_opts,
                function(style)
                    if not style then
                        return nil
                    end
                    return transform.toggle_equation_numbering(
                        style,
                        core.transform_opts(bufnr, pos, run_opts)
                    )
                end
            )
        end,
    })
end

return M
