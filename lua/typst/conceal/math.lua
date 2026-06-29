local conceal_util = require("typst.conceal.util")

local M = {}

local range_from_node = conceal_util.range_from_node
local range_text = conceal_util.range_text
local replacement_safe = conceal_util.replacement_safe
local children = conceal_util.children
local child_count = conceal_util.child_count
local node_text = conceal_util.node_text

local superscripts = {
    ["0"] = "⁰",
    ["1"] = "¹",
    ["2"] = "²",
    ["3"] = "³",
    ["4"] = "⁴",
    ["5"] = "⁵",
    ["6"] = "⁶",
    ["7"] = "⁷",
    ["8"] = "⁸",
    ["9"] = "⁹",
    ["+"] = "⁺",
    ["-"] = "⁻",
    ["="] = "⁼",
    ["("] = "⁽",
    [")"] = "⁾",
    n = "ⁿ",
}

local subscripts = {
    ["0"] = "₀",
    ["1"] = "₁",
    ["2"] = "₂",
    ["3"] = "₃",
    ["4"] = "₄",
    ["5"] = "₅",
    ["6"] = "₆",
    ["7"] = "₇",
    ["8"] = "₈",
    ["9"] = "₉",
    ["+"] = "₊",
    ["-"] = "₋",
    ["="] = "₌",
    ["("] = "₍",
    [")"] = "₎",
}

local function script_replacement(operator, operand)
    local table_for_operator = operator == "^" and superscripts or subscripts
    return table_for_operator[operand]
end

local function script_label(operator)
    if operator == "^" then
        return "superscript"
    end

    return "subscript"
end

function M.resolve_scripts(bufnr, node, opts)
    if not opts.categories.math_scripts then
        return {}
    end

    local matches = {}
    local node_children = children(node)
    for index = 1, #node_children - 1 do
        local operator_node = node_children[index]
        local operator = operator_node:type()
        if operator == "_" or operator == "^" then
            local operand_node = node_children[index + 1]
            local operand = node_text(bufnr, operand_node) or ""
            if
                child_count(operand_node) == 0
                and vim.fn.strchars(operand) == 1
            then
                local replacement = script_replacement(operator, operand)
                if replacement and replacement_safe(replacement, opts) then
                    local operator_range = range_from_node(operator_node)
                    local operand_range = range_from_node(operand_node)
                    local source_range = {
                        start_row = operator_range.start_row,
                        start_col = operator_range.start_col,
                        end_row = operand_range.end_row,
                        end_col = operand_range.end_col,
                    }
                    local label = script_label(operator)
                    matches[#matches + 1] = {
                        source = source_range,
                        reveal = range_from_node(node),
                        source_text = range_text(bufnr, source_range),
                        replacement = replacement,
                        kind = "math script",
                        title = label,
                        symbol_id = nil,
                        resolved_name = ("%s %s"):format(label, operand),
                        rule = "math_scripts",
                        category = "math_scripts",
                        provider = "Typst Tree-sitter syntax",
                        provider_version = nil,
                        requested_version = nil,
                        version_mismatch = false,
                        shadowed = "not applicable",
                        explicit = true,
                    }
                end
            end
        end
    end

    return matches
end

return M
