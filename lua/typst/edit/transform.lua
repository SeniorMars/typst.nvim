local arguments = require("typst.edit.arguments")
local delimiters = require("typst.edit.delimiters")
local equations = require("typst.edit.equations")
local figures = require("typst.edit.figures")
local functions = require("typst.edit.functions")
local headings = require("typst.edit.headings")
local labels = require("typst.edit.labels")
local lists = require("typst.edit.lists")
local markup = require("typst.edit.markup")
local raw = require("typst.edit.raw")
local smart = require("typst.edit.smart")
local surrounding = require("typst.edit.surrounding")

local M = {}

function M.toggle_list(kind, opts)
    return lists.toggle(kind, opts)
end

function M.toggle_bullet_list(opts)
    return lists.toggle_bullet(opts)
end

function M.toggle_numbered_list(opts)
    return lists.toggle_numbered(opts)
end

function M.change_delimiter(target, opts)
    return delimiters.change(target, opts)
end

function M.surround_delete_delimiter(target, opts)
    return delimiters.delete(target, opts)
end

function M.surround_change_delimiter(target, opts)
    return delimiters.change(target, opts)
end

function M.surround_delete_call(opts)
    return functions.unwrap_function(opts)
end

function M.surround_change_call(name, opts)
    return functions.change_function(name, opts)
end

function M.surround_delete_block(opts)
    return delimiters.delete("block", opts)
end

function M.surround_change_block(target, opts)
    return delimiters.change(target or "content", opts)
end

function M.surround_delete_equation(opts)
    return delimiters.delete("equation", opts)
end

function M.surround_change_equation(target, opts)
    return delimiters.change(target or "content", opts)
end

function M.split_arguments(opts)
    return arguments.split_arguments(opts)
end

function M.join_arguments(opts)
    return arguments.join_arguments(opts)
end

function M.toggle_arguments(opts)
    return arguments.toggle_arguments(opts)
end

function M.toggle_trailing_comma(style, opts)
    return arguments.toggle_trailing_comma(style, opts)
end

function M.add_trailing_comma(opts)
    return arguments.add_trailing_comma(opts)
end

function M.remove_trailing_comma(opts)
    return arguments.remove_trailing_comma(opts)
end

function M.name_arguments(opts)
    return arguments.name_arguments(opts)
end

function M.toggle_label(opts)
    return labels.toggle_label(opts)
end

function M.toggle_reference(opts)
    return labels.toggle_reference(opts)
end

function M.toggle_label_reference(opts)
    return labels.toggle_label_reference(opts)
end

function M.convert_equation(style, opts)
    return equations.convert_equation(style, opts)
end

function M.toggle_equation_numbering(style, opts)
    return equations.toggle_equation_numbering(style, opts)
end

function M.toggle_fraction(opts)
    return smart.toggle_fraction(opts)
end

function M.toggle_delimiter_size(opts)
    return smart.toggle_delimiter_size(opts)
end

function M.toggle_line_break(opts)
    return smart.toggle_line_break(opts)
end

function M.create_function(name, opts)
    return smart.create_function(name, opts)
end

function M.smart_close(opts)
    return smart.smart_close(opts)
end

function M.convert_raw(style, opts)
    return raw.convert_raw(style, opts)
end

function M.surround(kind, opts)
    return surrounding.surround(kind, opts)
end

function M.surround_function(name, opts)
    return surrounding.surround_function(name, opts)
end

function M.surround_content(opts)
    return surrounding.surround_content(opts)
end

function M.surround_equation(opts)
    return surrounding.surround_equation(opts)
end

function M.surround_figure(opts)
    return surrounding.surround_figure(opts)
end

function M.surround_block(opts)
    return surrounding.surround_block(opts)
end

function M.surround_strong(opts)
    return surrounding.surround_strong(opts)
end

function M.surround_emph(opts)
    return surrounding.surround_emph(opts)
end

function M.toggle_figure(opts)
    return figures.toggle_figure(opts)
end

function M.promote_heading(opts)
    return headings.promote_heading(opts)
end

function M.demote_heading(opts)
    return headings.demote_heading(opts)
end

function M.change_function(name, opts)
    return functions.change_function(name, opts)
end

function M.unwrap_function(opts)
    return functions.unwrap_function(opts)
end

function M.toggle_markup(kind, opts)
    return markup.toggle_markup(kind, opts)
end

function M.toggle_strong(opts)
    return markup.toggle_strong(opts)
end

function M.toggle_emph(opts)
    return markup.toggle_emph(opts)
end

return M
