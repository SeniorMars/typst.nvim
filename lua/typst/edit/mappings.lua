local config = require("typst.config")
local edit_repeat = require("typst.edit.repeat")
local ftplugin_state = require("typst.core.ftplugin_state")
local plugs = require("typst.edit.plugs")

local M = {}

local motion_modes = plugs.motion_modes

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

function M.apply(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local mappings = config.unsafe_get().mappings
    if not mappings or mappings.enabled == false then
        return
    end

    M.register_plugs()

    map(
        bufnr,
        motion_modes,
        mappings.next_heading,
        "<Plug>(typst-next-heading)",
        "Typst next heading"
    )
    map(
        bufnr,
        motion_modes,
        mappings.previous_heading,
        "<Plug>(typst-previous-heading)",
        "Typst previous heading"
    )
    map(
        bufnr,
        motion_modes,
        mappings.next_heading_end,
        "<Plug>(typst-next-heading-end)",
        "Typst next heading end"
    )
    map(
        bufnr,
        motion_modes,
        mappings.previous_heading_end,
        "<Plug>(typst-previous-heading-end)",
        "Typst previous heading end"
    )
    map(
        bufnr,
        motion_modes,
        mappings.next_block,
        "<Plug>(typst-next-block)",
        "Typst next structural block"
    )
    map(
        bufnr,
        motion_modes,
        mappings.previous_block,
        "<Plug>(typst-previous-block)",
        "Typst previous structural block"
    )
    map(
        bufnr,
        motion_modes,
        mappings.next_block_end,
        "<Plug>(typst-next-block-end)",
        "Typst next structural block end"
    )
    map(
        bufnr,
        motion_modes,
        mappings.previous_block_end,
        "<Plug>(typst-previous-block-end)",
        "Typst previous structural block end"
    )
    map(
        bufnr,
        motion_modes,
        mappings.next_equation,
        "<Plug>(typst-next-equation)",
        "Typst next equation"
    )
    map(
        bufnr,
        motion_modes,
        mappings.previous_equation,
        "<Plug>(typst-previous-equation)",
        "Typst previous equation"
    )
    map(
        bufnr,
        motion_modes,
        mappings.next_equation_end,
        "<Plug>(typst-next-equation-end)",
        "Typst next equation end"
    )
    map(
        bufnr,
        motion_modes,
        mappings.previous_equation_end,
        "<Plug>(typst-previous-equation-end)",
        "Typst previous equation end"
    )
    map(
        bufnr,
        motion_modes,
        mappings.next_raw_block,
        "<Plug>(typst-next-raw-block)",
        "Typst next raw block"
    )
    map(
        bufnr,
        motion_modes,
        mappings.previous_raw_block,
        "<Plug>(typst-previous-raw-block)",
        "Typst previous raw block"
    )
    map(
        bufnr,
        motion_modes,
        mappings.next_comment,
        "<Plug>(typst-next-comment)",
        "Typst next comment"
    )
    map(
        bufnr,
        motion_modes,
        mappings.previous_comment,
        "<Plug>(typst-previous-comment)",
        "Typst previous comment"
    )
    map(
        bufnr,
        "n",
        mappings.match,
        "<Plug>(typst-match)",
        "Typst matching delimiter"
    )
    map(
        bufnr,
        "n",
        mappings.follow,
        "<Plug>(typst-follow)",
        "Typst follow target under cursor"
    )
    map(bufnr, "n", mappings.hover, "<Plug>(typst-hover)", "Typst LSP hover")
    edit_repeat.map(bufnr, mappings.repeat_transform)

    local command_maps = mappings.commands or {}
    map(
        bufnr,
        "n",
        command_maps.watch,
        "<Plug>(typst-watch)",
        "Typst watch project"
    )
    map(
        bufnr,
        "n",
        command_maps.compile,
        "<Plug>(typst-compile)",
        "Typst compile project"
    )
    map(
        bufnr,
        "n",
        command_maps.stop,
        "<Plug>(typst-stop)",
        "Typst stop compiler"
    )
    map(
        bufnr,
        "n",
        command_maps.view,
        "<Plug>(typst-view)",
        "Typst view output"
    )
    map(
        bufnr,
        "n",
        command_maps.forward,
        "<Plug>(typst-view-forward)",
        "Typst forward-search viewer"
    )
    map(
        bufnr,
        "n",
        command_maps.errors,
        "<Plug>(typst-errors)",
        "Typst compiler diagnostics"
    )
    map(
        bufnr,
        "n",
        command_maps.output,
        "<Plug>(typst-compile-output)",
        "Typst compiler output"
    )
    map(
        bufnr,
        "n",
        command_maps.info,
        "<Plug>(typst-info)",
        "Typst project info"
    )
    map(
        bufnr,
        "n",
        command_maps.toc,
        "<Plug>(typst-toc-toggle)",
        "Typst toggle TOC"
    )
    map(
        bufnr,
        "n",
        command_maps.clean,
        "<Plug>(typst-clean)",
        "Typst clean artifacts"
    )
    map(bufnr, "n", command_maps.log, "<Plug>(typst-log)", "Typst log")

    local insert_maps = mappings.insert or {}
    map(
        bufnr,
        "i",
        insert_maps.strong,
        "<Plug>(typst-insert-strong)",
        "Typst insert strong markup"
    )
    map(
        bufnr,
        "i",
        insert_maps.emph,
        "<Plug>(typst-insert-emph)",
        "Typst insert emphasis markup"
    )
    map(
        bufnr,
        "i",
        insert_maps.math,
        "<Plug>(typst-insert-math)",
        "Typst insert inline equation"
    )
    map(
        bufnr,
        "i",
        insert_maps.content,
        "<Plug>(typst-insert-content)",
        "Typst insert content brackets"
    )
    map(
        bufnr,
        "i",
        insert_maps.code,
        "<Plug>(typst-insert-code)",
        "Typst insert code expression"
    )
    map(
        bufnr,
        "i",
        insert_maps.raw,
        "<Plug>(typst-insert-raw)",
        "Typst insert raw text"
    )

    local objects = mappings.textobjects or {}
    map(
        bufnr,
        { "x", "o" },
        objects.inner_heading,
        "<Plug>(typst-inner-heading)",
        "Typst inner heading"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_heading,
        "<Plug>(typst-outer-heading)",
        "Typst outer heading"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_section,
        "<Plug>(typst-inner-section)",
        "Typst inner section"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_section,
        "<Plug>(typst-outer-section)",
        "Typst outer section"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_equation,
        "<Plug>(typst-inner-equation)",
        "Typst inner equation"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_equation,
        "<Plug>(typst-outer-equation)",
        "Typst outer equation"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_delimiter,
        "<Plug>(typst-inner-delimiter)",
        "Typst inner delimiter"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_delimiter,
        "<Plug>(typst-outer-delimiter)",
        "Typst outer delimiter"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_content,
        "<Plug>(typst-inner-content)",
        "Typst inner content block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_content,
        "<Plug>(typst-outer-content)",
        "Typst outer content block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_block,
        "<Plug>(typst-inner-block)",
        "Typst inner block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_block,
        "<Plug>(typst-outer-block)",
        "Typst outer block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_structural_block,
        "<Plug>(typst-inner-structural-block)",
        "Typst inner structural block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_structural_block,
        "<Plug>(typst-outer-structural-block)",
        "Typst outer structural block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_code_block,
        "<Plug>(typst-inner-code-block)",
        "Typst inner code block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_code_block,
        "<Plug>(typst-outer-code-block)",
        "Typst outer code block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_raw_block,
        "<Plug>(typst-inner-raw-block)",
        "Typst inner raw block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_raw_block,
        "<Plug>(typst-outer-raw-block)",
        "Typst outer raw block"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_call,
        "<Plug>(typst-inner-call)",
        "Typst inner function call"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_call,
        "<Plug>(typst-outer-call)",
        "Typst outer function call"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_argument,
        "<Plug>(typst-inner-argument)",
        "Typst inner argument"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_argument,
        "<Plug>(typst-outer-argument)",
        "Typst outer argument"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_list_item,
        "<Plug>(typst-inner-list-item)",
        "Typst inner list item"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_list_item,
        "<Plug>(typst-outer-list-item)",
        "Typst outer list item"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_label,
        "<Plug>(typst-inner-label)",
        "Typst inner label or reference"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_label,
        "<Plug>(typst-outer-label)",
        "Typst outer label or reference"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.inner_import,
        "<Plug>(typst-inner-import)",
        "Typst inner import"
    )
    map(
        bufnr,
        { "x", "o" },
        objects.outer_import,
        "<Plug>(typst-outer-import)",
        "Typst outer import"
    )
end

return M
