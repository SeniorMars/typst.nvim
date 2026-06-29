local follow = require("typst.navigation.follow")
local insert = require("typst.edit.insert")
local matchparen = require("typst.edit.matchparen")
local motions = require("typst.edit.motions")
local tables = require("typst.core.tables")
local textobjects = require("typst.edit.textobjects")
local transaction = require("typst.edit.transaction")
local transform = require("typst.edit.transform")

local M = {}

local unpack = tables.unpack

M.motion_modes = { "n", "x", "o" }

-- Register stable <Plug> targets once; user-facing keys are buffer-local and
-- installed from config later. That lets users remap Typst behavior per buffer
-- without rebuilding the implementation callbacks.

local function plug(name)
    return ("<Plug>(typst-%s)"):format(name)
end

local function set_plug(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
end

local function motion_rhs(method)
    return function()
        motions[method]({ count = vim.v.count1 })
    end
end

local function transform_rhs(method, args)
    return function()
        return transaction.counted_current(function()
            return transform[method](unpack(args or {}))
        end)
    end
end

local function transform_prompt_rhs(method, prompt)
    return function()
        local value = vim.fn.input(prompt)
        if value ~= nil and value ~= "" then
            return transaction.counted_current(function()
                return transform[method](value)
            end)
        end
    end
end

local function insert_rhs(method)
    return function()
        insert[method]()
    end
end

local function api_rhs(namespace, method)
    return function()
        return require("typst")[namespace][method]()
    end
end

local function textobject_rhs(kind, part)
    return function()
        textobjects.select(
            kind,
            part,
            { count = vim.v.count > 0 and vim.v.count or 1 }
        )
    end
end

function M.register_motions()
    for _, spec in ipairs({
        { "next-heading", "next_heading", "Typst next heading" },
        { "previous-heading", "previous_heading", "Typst previous heading" },
        { "next-heading-end", "next_heading_end", "Typst next heading end" },
        {
            "previous-heading-end",
            "previous_heading_end",
            "Typst previous heading end",
        },
        { "next-block", "next_block", "Typst next structural block" },
        {
            "previous-block",
            "previous_block",
            "Typst previous structural block",
        },
        {
            "next-block-end",
            "next_block_end",
            "Typst next structural block end",
        },
        {
            "previous-block-end",
            "previous_block_end",
            "Typst previous structural block end",
        },
        { "next-equation", "next_equation", "Typst next equation" },
        { "previous-equation", "previous_equation", "Typst previous equation" },
        { "next-equation-end", "next_equation_end", "Typst next equation end" },
        {
            "previous-equation-end",
            "previous_equation_end",
            "Typst previous equation end",
        },
        { "next-raw-block", "next_raw_block", "Typst next raw block" },
        {
            "previous-raw-block",
            "previous_raw_block",
            "Typst previous raw block",
        },
        { "next-comment", "next_comment", "Typst next comment" },
        { "previous-comment", "previous_comment", "Typst previous comment" },
    }) do
        set_plug(M.motion_modes, plug(spec[1]), motion_rhs(spec[2]), spec[3])
    end
end

function M.register_navigation()
    set_plug("n", plug("follow"), function()
        follow.follow()
    end, "Typst follow target under cursor")

    set_plug("n", plug("hover"), function()
        require("typst").navigation.hover()
    end, "Typst LSP hover")

    set_plug("n", plug("match"), function()
        matchparen.jump()
    end, "Typst matching delimiter")
end

function M.register_commands()
    for _, spec in ipairs({
        { "watch", "compiler", "watch", "Typst watch project" },
        { "compile", "compiler", "compile", "Typst compile project" },
        { "stop", "compiler", "stop", "Typst stop compiler" },
        { "view", "viewer", "view", "Typst view output" },
        {
            "view-forward",
            "viewer",
            "view_forward",
            "Typst forward-search viewer",
        },
        {
            "errors",
            "diagnostics",
            "errors",
            "Typst compiler diagnostics",
        },
        {
            "compile-output",
            "compiler",
            "output",
            "Typst compiler output",
        },
        { "info", "ui", "info", "Typst project info" },
        { "toc-toggle", "navigation", "toc_toggle", "Typst toggle TOC" },
        { "clean", "viewer", "clean", "Typst clean artifacts" },
        { "log", "ui", "log", "Typst log" },
    }) do
        set_plug("n", plug(spec[1]), api_rhs(spec[2], spec[3]), spec[4])
    end
end

function M.register_transforms()
    set_plug(
        "n",
        plug("surround-delete-call"),
        transform_rhs("surround_delete_call"),
        "Typst delete surrounding call"
    )
    set_plug(
        "n",
        plug("surround-change-call"),
        transform_prompt_rhs("surround_change_call", "Typst function: "),
        "Typst change surrounding call"
    )
    set_plug(
        "n",
        plug("surround-delete-delimiter"),
        transform_rhs("surround_delete_delimiter"),
        "Typst delete surrounding delimiter"
    )
    set_plug(
        "n",
        plug("surround-change-delimiter"),
        transform_prompt_rhs("surround_change_delimiter", "Typst delimiter: "),
        "Typst change surrounding delimiter"
    )
    set_plug(
        "n",
        plug("surround-delete-block"),
        transform_rhs("surround_delete_block"),
        "Typst delete surrounding block"
    )
    set_plug(
        "n",
        plug("surround-change-block"),
        transform_prompt_rhs("surround_change_block", "Typst delimiter: "),
        "Typst change surrounding block"
    )
    set_plug(
        "n",
        plug("surround-delete-equation"),
        transform_rhs("surround_delete_equation"),
        "Typst delete surrounding equation"
    )
    set_plug(
        "n",
        plug("surround-change-equation"),
        transform_prompt_rhs("surround_change_equation", "Typst delimiter: "),
        "Typst change surrounding equation"
    )
    set_plug(
        "n",
        plug("create-function"),
        transform_prompt_rhs("create_function", "Typst function: "),
        "Typst create function call"
    )

    for _, spec in ipairs({
        {
            "n",
            "unwrap-function",
            "unwrap_function",
            nil,
            "Typst unwrap function call",
        },
        {
            "n",
            "change-delimiter-content",
            "change_delimiter",
            { "content" },
            "Typst change delimiter to content brackets",
        },
        {
            "n",
            "change-delimiter-block",
            "change_delimiter",
            { "block" },
            "Typst change delimiter to code block braces",
        },
        {
            "n",
            "change-delimiter-group",
            "change_delimiter",
            { "group" },
            "Typst change delimiter to parentheses",
        },
        {
            "n",
            "change-delimiter-equation",
            "change_delimiter",
            { "equation" },
            "Typst change delimiter to equation delimiters",
        },
        {
            "n",
            "split-arguments",
            "split_arguments",
            nil,
            "Typst split function arguments",
        },
        {
            "n",
            "join-arguments",
            "join_arguments",
            nil,
            "Typst join function arguments",
        },
        {
            "n",
            "toggle-arguments",
            "toggle_arguments",
            nil,
            "Typst toggle function arguments",
        },
        {
            "n",
            "name-arguments",
            "name_arguments",
            nil,
            "Typst name positional arguments",
        },
        {
            "n",
            "toggle-trailing-comma",
            "toggle_trailing_comma",
            { "toggle" },
            "Typst toggle trailing comma",
        },
        {
            "n",
            "add-trailing-comma",
            "add_trailing_comma",
            nil,
            "Typst add trailing comma",
        },
        {
            "n",
            "remove-trailing-comma",
            "remove_trailing_comma",
            nil,
            "Typst remove trailing comma",
        },
        { "n", "toggle-label", "toggle_label", nil, "Typst toggle label form" },
        {
            "n",
            "toggle-reference",
            "toggle_reference",
            nil,
            "Typst toggle reference form",
        },
        {
            "n",
            "toggle-label-reference",
            "toggle_label_reference",
            nil,
            "Typst toggle label or reference form",
        },
        {
            { "n", "x" },
            "surround-content",
            "surround_content",
            nil,
            "Typst surround with content brackets",
        },
        {
            { "n", "x" },
            "surround-equation",
            "surround_equation",
            nil,
            "Typst surround with equation delimiters",
        },
        {
            { "n", "x" },
            "surround-figure",
            "surround_figure",
            nil,
            "Typst surround with figure",
        },
        {
            { "n", "x" },
            "surround-block",
            "surround_block",
            nil,
            "Typst surround with code block",
        },
        {
            { "n", "x" },
            "surround-strong",
            "surround_strong",
            nil,
            "Typst surround with strong markup",
        },
        {
            { "n", "x" },
            "surround-emph",
            "surround_emph",
            nil,
            "Typst surround with emphasis markup",
        },
        {
            "n",
            "toggle-strong",
            "toggle_strong",
            nil,
            "Typst toggle strong markup",
        },
        {
            "n",
            "toggle-emph",
            "toggle_emph",
            nil,
            "Typst toggle emphasis markup",
        },
        {
            { "n", "x" },
            "toggle-list",
            "toggle_list",
            { "toggle" },
            "Typst toggle list kind",
        },
        {
            { "n", "x" },
            "toggle-bullet-list",
            "toggle_bullet_list",
            nil,
            "Typst toggle bullet list",
        },
        {
            { "n", "x" },
            "toggle-numbered-list",
            "toggle_numbered_list",
            nil,
            "Typst toggle numbered list",
        },
        {
            "n",
            "convert-raw",
            "convert_raw",
            { "toggle" },
            "Typst convert raw text",
        },
        {
            "n",
            "toggle-fraction",
            "toggle_fraction",
            nil,
            "Typst toggle fraction form",
        },
        {
            "n",
            "toggle-delimiter-size",
            "toggle_delimiter_size",
            nil,
            "Typst toggle delimiter size form",
        },
        {
            "n",
            "toggle-line-break",
            "toggle_line_break",
            nil,
            "Typst toggle line break",
        },
        {
            "n",
            "smart-close",
            "smart_close",
            nil,
            "Typst smart close delimiter",
        },
        {
            "n",
            "toggle-equation-numbering",
            "toggle_equation_numbering",
            { "toggle" },
            "Typst toggle equation numbering",
        },
        {
            { "n", "x" },
            "toggle-figure",
            "toggle_figure",
            nil,
            "Typst toggle figure wrapping",
        },
    }) do
        set_plug(
            spec[1],
            plug(spec[2]),
            transform_rhs(spec[3], spec[4]),
            spec[5]
        )
    end
end

function M.register_insertions()
    for _, spec in ipairs({
        { "strong", "strong", "Typst insert strong markup" },
        { "emph", "emph", "Typst insert emphasis markup" },
        { "math", "math", "Typst insert inline equation" },
        { "content", "content", "Typst insert content brackets" },
        { "code", "code", "Typst insert code expression" },
        { "raw", "raw", "Typst insert raw text" },
    }) do
        set_plug("i", plug("insert-" .. spec[1]), insert_rhs(spec[2]), spec[3])
    end
end

function M.register_textobjects()
    for _, spec in ipairs({
        { "heading", "heading", "heading" },
        { "section", "section", "section" },
        { "equation", "equation", "equation" },
        { "delimiter", "delimiter", "delimiter pair" },
        { "content", "content", "content block" },
        { "block", "block", "block" },
        { "structural-block", "structural_block", "structural block" },
        { "code-block", "code_block", "code block" },
        { "raw-block", "raw_block", "raw block" },
        { "call", "call", "function call" },
        { "argument", "argument", "argument" },
        { "list-item", "list_item", "list item" },
        { "label", "label", "label or reference" },
        { "import", "import", "import" },
    }) do
        set_plug(
            { "x", "o" },
            plug("inner-" .. spec[1]),
            textobject_rhs(spec[2], "inner"),
            "Typst inner " .. spec[3]
        )
        set_plug(
            { "x", "o" },
            plug("outer-" .. spec[1]),
            textobject_rhs(spec[2], "outer"),
            "Typst outer " .. spec[3]
        )
    end
end

function M.register()
    M.register_motions()
    M.register_navigation()
    M.register_commands()
    M.register_transforms()
    M.register_insertions()
    M.register_textobjects()
end

return M
