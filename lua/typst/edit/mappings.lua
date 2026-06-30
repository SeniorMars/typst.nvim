local config = require("typst.config")
local edit_repeat = require("typst.edit.repeat")
local ftplugin_state = require("typst.core.ftplugin_state")
local plugs = require("typst.edit.plugs")

local M = {}

local motion_modes = plugs.motion_modes
local textobject_modes = { "x", "o" }

local motion_specs = {
    {
        key = "next_heading",
        plug = "<Plug>(typst-next-heading)",
        desc = "Typst next heading",
    },
    {
        key = "previous_heading",
        plug = "<Plug>(typst-previous-heading)",
        desc = "Typst previous heading",
    },
    {
        key = "next_heading_end",
        plug = "<Plug>(typst-next-heading-end)",
        desc = "Typst next heading end",
    },
    {
        key = "previous_heading_end",
        plug = "<Plug>(typst-previous-heading-end)",
        desc = "Typst previous heading end",
    },
    {
        key = "next_block",
        plug = "<Plug>(typst-next-block)",
        desc = "Typst next structural block",
    },
    {
        key = "previous_block",
        plug = "<Plug>(typst-previous-block)",
        desc = "Typst previous structural block",
    },
    {
        key = "next_block_end",
        plug = "<Plug>(typst-next-block-end)",
        desc = "Typst next structural block end",
    },
    {
        key = "previous_block_end",
        plug = "<Plug>(typst-previous-block-end)",
        desc = "Typst previous structural block end",
    },
    {
        key = "next_equation",
        plug = "<Plug>(typst-next-equation)",
        desc = "Typst next equation",
    },
    {
        key = "previous_equation",
        plug = "<Plug>(typst-previous-equation)",
        desc = "Typst previous equation",
    },
    {
        key = "next_equation_end",
        plug = "<Plug>(typst-next-equation-end)",
        desc = "Typst next equation end",
    },
    {
        key = "previous_equation_end",
        plug = "<Plug>(typst-previous-equation-end)",
        desc = "Typst previous equation end",
    },
    {
        key = "next_raw_block",
        plug = "<Plug>(typst-next-raw-block)",
        desc = "Typst next raw block",
    },
    {
        key = "previous_raw_block",
        plug = "<Plug>(typst-previous-raw-block)",
        desc = "Typst previous raw block",
    },
    {
        key = "next_comment",
        plug = "<Plug>(typst-next-comment)",
        desc = "Typst next comment",
    },
    {
        key = "previous_comment",
        plug = "<Plug>(typst-previous-comment)",
        desc = "Typst previous comment",
    },
}

local normal_specs = {
    {
        key = "match",
        plug = "<Plug>(typst-match)",
        desc = "Typst matching delimiter",
    },
    {
        key = "follow",
        plug = "<Plug>(typst-follow)",
        desc = "Typst follow target under cursor",
    },
    {
        key = "hover",
        plug = "<Plug>(typst-hover)",
        desc = "Typst LSP hover",
    },
}

local command_specs = {
    {
        key = "watch",
        plug = "<Plug>(typst-watch)",
        desc = "Typst watch project",
    },
    {
        key = "compile",
        plug = "<Plug>(typst-compile)",
        desc = "Typst compile project",
    },
    {
        key = "stop",
        plug = "<Plug>(typst-stop)",
        desc = "Typst stop compiler",
    },
    {
        key = "view",
        plug = "<Plug>(typst-view)",
        desc = "Typst view output",
    },
    {
        key = "forward",
        plug = "<Plug>(typst-view-forward)",
        desc = "Typst forward-search viewer",
    },
    {
        key = "errors",
        plug = "<Plug>(typst-errors)",
        desc = "Typst compiler diagnostics",
    },
    {
        key = "output",
        plug = "<Plug>(typst-compile-output)",
        desc = "Typst compiler output",
    },
    {
        key = "info",
        plug = "<Plug>(typst-info)",
        desc = "Typst project info",
    },
    {
        key = "toc",
        plug = "<Plug>(typst-toc-toggle)",
        desc = "Typst toggle TOC",
    },
    {
        key = "clean",
        plug = "<Plug>(typst-clean)",
        desc = "Typst clean artifacts",
    },
    {
        key = "log",
        plug = "<Plug>(typst-log)",
        desc = "Typst log",
    },
}

local insert_specs = {
    {
        key = "strong",
        plug = "<Plug>(typst-insert-strong)",
        desc = "Typst insert strong markup",
    },
    {
        key = "emph",
        plug = "<Plug>(typst-insert-emph)",
        desc = "Typst insert emphasis markup",
    },
    {
        key = "math",
        plug = "<Plug>(typst-insert-math)",
        desc = "Typst insert inline equation",
    },
    {
        key = "content",
        plug = "<Plug>(typst-insert-content)",
        desc = "Typst insert content brackets",
    },
    {
        key = "code",
        plug = "<Plug>(typst-insert-code)",
        desc = "Typst insert code expression",
    },
    {
        key = "raw",
        plug = "<Plug>(typst-insert-raw)",
        desc = "Typst insert raw text",
    },
}

local textobject_specs = {
    {
        key = "inner_heading",
        plug = "<Plug>(typst-inner-heading)",
        desc = "Typst inner heading",
    },
    {
        key = "outer_heading",
        plug = "<Plug>(typst-outer-heading)",
        desc = "Typst outer heading",
    },
    {
        key = "inner_section",
        plug = "<Plug>(typst-inner-section)",
        desc = "Typst inner section",
    },
    {
        key = "outer_section",
        plug = "<Plug>(typst-outer-section)",
        desc = "Typst outer section",
    },
    {
        key = "inner_equation",
        plug = "<Plug>(typst-inner-equation)",
        desc = "Typst inner equation",
    },
    {
        key = "outer_equation",
        plug = "<Plug>(typst-outer-equation)",
        desc = "Typst outer equation",
    },
    {
        key = "inner_delimiter",
        plug = "<Plug>(typst-inner-delimiter)",
        desc = "Typst inner delimiter",
    },
    {
        key = "outer_delimiter",
        plug = "<Plug>(typst-outer-delimiter)",
        desc = "Typst outer delimiter",
    },
    {
        key = "inner_content",
        plug = "<Plug>(typst-inner-content)",
        desc = "Typst inner content block",
    },
    {
        key = "outer_content",
        plug = "<Plug>(typst-outer-content)",
        desc = "Typst outer content block",
    },
    {
        key = "inner_block",
        plug = "<Plug>(typst-inner-block)",
        desc = "Typst inner block",
    },
    {
        key = "outer_block",
        plug = "<Plug>(typst-outer-block)",
        desc = "Typst outer block",
    },
    {
        key = "inner_structural_block",
        plug = "<Plug>(typst-inner-structural-block)",
        desc = "Typst inner structural block",
    },
    {
        key = "outer_structural_block",
        plug = "<Plug>(typst-outer-structural-block)",
        desc = "Typst outer structural block",
    },
    {
        key = "inner_code_block",
        plug = "<Plug>(typst-inner-code-block)",
        desc = "Typst inner code block",
    },
    {
        key = "outer_code_block",
        plug = "<Plug>(typst-outer-code-block)",
        desc = "Typst outer code block",
    },
    {
        key = "inner_raw_block",
        plug = "<Plug>(typst-inner-raw-block)",
        desc = "Typst inner raw block",
    },
    {
        key = "outer_raw_block",
        plug = "<Plug>(typst-outer-raw-block)",
        desc = "Typst outer raw block",
    },
    {
        key = "inner_call",
        plug = "<Plug>(typst-inner-call)",
        desc = "Typst inner function call",
    },
    {
        key = "outer_call",
        plug = "<Plug>(typst-outer-call)",
        desc = "Typst outer function call",
    },
    {
        key = "inner_argument",
        plug = "<Plug>(typst-inner-argument)",
        desc = "Typst inner argument",
    },
    {
        key = "outer_argument",
        plug = "<Plug>(typst-outer-argument)",
        desc = "Typst outer argument",
    },
    {
        key = "inner_list_item",
        plug = "<Plug>(typst-inner-list-item)",
        desc = "Typst inner list item",
    },
    {
        key = "outer_list_item",
        plug = "<Plug>(typst-outer-list-item)",
        desc = "Typst outer list item",
    },
    {
        key = "inner_label",
        plug = "<Plug>(typst-inner-label)",
        desc = "Typst inner label or reference",
    },
    {
        key = "outer_label",
        plug = "<Plug>(typst-outer-label)",
        desc = "Typst outer label or reference",
    },
    {
        key = "inner_import",
        plug = "<Plug>(typst-inner-import)",
        desc = "Typst inner import",
    },
    {
        key = "outer_import",
        plug = "<Plug>(typst-outer-import)",
        desc = "Typst outer import",
    },
}

function M._specs_for_tests()
    return {
        motions = vim.deepcopy(motion_specs),
        normal = vim.deepcopy(normal_specs),
        commands = vim.deepcopy(command_specs),
        insert = vim.deepcopy(insert_specs),
        textobjects = vim.deepcopy(textobject_specs),
        motion_modes = vim.deepcopy(motion_modes),
        textobject_modes = vim.deepcopy(textobject_modes),
    }
end

function M.register_plugs()
    plugs.register()
end

local function map(bufnr, mode, lhs, rhs, desc)
    -- Falsey/empty mapping values are the config-level way to disable a
    -- default key without disabling the underlying <Plug> action.
    if lhs == nil or lhs == false or lhs == "" then
        return
    end

    ftplugin_state.set_buffer_mapping(bufnr, mode, lhs, rhs, {
        remap = true,
        silent = true,
        desc = desc,
    })
end

local function apply_specs(bufnr, mode, source, specs)
    source = source or {}
    for _, spec in ipairs(specs) do
        map(bufnr, mode, source[spec.key], spec.plug, spec.desc)
    end
end

function M.apply(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local mappings = config.unsafe_get().mappings
    if not mappings or mappings.enabled == false then
        return
    end

    M.register_plugs()

    apply_specs(bufnr, motion_modes, mappings, motion_specs)
    apply_specs(bufnr, "n", mappings, normal_specs)
    edit_repeat.map(bufnr, mappings.repeat_transform)
    apply_specs(bufnr, "n", mappings.commands, command_specs)
    apply_specs(bufnr, "i", mappings.insert, insert_specs)
    apply_specs(bufnr, textobject_modes, mappings.textobjects, textobject_specs)
end

return M
