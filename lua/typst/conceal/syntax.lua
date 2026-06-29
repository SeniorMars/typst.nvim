local conceal_util = require("typst.conceal.util")

local M = {}

local first_child = conceal_util.first_child
local node_text = conceal_util.node_text
local range_from_node = conceal_util.range_from_node
local range_text = conceal_util.range_text
local replacement_safe = conceal_util.replacement_safe

local function_wrappers = {
    strong = "strong function wrapper",
    emph = "emphasis function wrapper",
    underline = "underline function wrapper",
    strike = "strike function wrapper",
}

function M.range_match(
    bufnr,
    source_range,
    reveal_range,
    opts,
    category,
    replacement,
    kind,
    resolved_name,
    extra
)
    if
        not opts.categories[category] or not replacement_safe(replacement, opts)
    then
        return nil
    end

    local match = {
        source = source_range,
        reveal = reveal_range,
        source_text = range_text(bufnr, source_range),
        replacement = replacement,
        kind = kind,
        title = resolved_name,
        symbol_id = nil,
        resolved_name = resolved_name,
        rule = category,
        category = category,
        provider = "Typst Tree-sitter syntax",
        provider_version = nil,
        requested_version = nil,
        version_mismatch = false,
        shadowed = "not applicable",
        explicit = true,
    }

    if extra then
        for key, value in pairs(extra) do
            match[key] = value
        end
    end

    return match
end

function M.node(
    bufnr,
    node,
    opts,
    category,
    replacement,
    kind,
    resolved_name,
    reveal_node
)
    return M.range_match(
        bufnr,
        range_from_node(node),
        reveal_node and range_from_node(reveal_node) or range_from_node(node),
        opts,
        category,
        replacement,
        kind,
        resolved_name,
        {
            title = resolved_name,
        }
    )
end

function M.reference_category(opts)
    if opts.categories.reference_markers then
        return "reference_markers"
    end
end

function M.list_marker(bufnr, node, opts)
    if not opts.categories.lists then
        return nil
    end

    local source_range = range_from_node(node)
    if source_range.start_row == source_range.end_row then
        local line = vim.api.nvim_buf_get_lines(
            bufnr,
            source_range.start_row,
            source_range.start_row + 1,
            false
        )[1] or ""
        if
            line:sub(source_range.end_col + 1, source_range.end_col + 1) == " "
        then
            source_range.end_col = source_range.end_col + 1
        end
    end

    return M.range_match(
        bufnr,
        source_range,
        range_from_node(node:parent() or node),
        opts,
        "lists",
        "",
        "list marker",
        "list marker"
    )
end

function M.label_delimiters(bufnr, node, opts)
    if not opts.categories.labels then
        return nil
    end

    local range = range_from_node(node)
    local text = range_text(bufnr, range)
    if text:sub(1, 1) ~= "<" or text:sub(-1) ~= ">" then
        return nil
    end

    return {
        M.range_match(bufnr, {
            start_row = range.start_row,
            start_col = range.start_col,
            end_row = range.start_row,
            end_col = range.start_col + 1,
        }, range, opts, "labels", "", "label delimiter", "label delimiter"),
        M.range_match(bufnr, {
            start_row = range.end_row,
            start_col = range.end_col - 1,
            end_row = range.end_row,
            end_col = range.end_col,
        }, range, opts, "labels", "", "label delimiter", "label delimiter"),
    }
end

local function function_wrapper_enabled(opts, name)
    if not function_wrappers[name] then
        return false
    end

    local configured = opts.categories.function_wrappers
    if type(configured) == "boolean" then
        return configured
    end

    if type(configured) == "table" then
        return configured[name] == true
    end

    return false
end

local function wrapper_part(
    bufnr,
    source_range,
    reveal_range,
    source_text,
    name,
    part
)
    return {
        source = source_range,
        reveal = reveal_range,
        source_text = source_text,
        replacement = "",
        kind = "function wrapper",
        title = function_wrappers[name],
        symbol_id = nil,
        resolved_name = name,
        rule = "function_wrappers",
        category = "function_wrappers",
        provider = "Typst Tree-sitter syntax",
        provider_version = nil,
        requested_version = nil,
        version_mismatch = false,
        shadowed = "not applicable",
        explicit = true,
        wrapper = name,
        part = part,
    }
end

function M.function_wrapper(bufnr, call, opts)
    local ident = first_child(call, "identifier")
    local arguments = first_child(call, "arguments")
    local content = first_child(call, "content")
        or (arguments and first_child(arguments, "content_block"))
    if not ident or not content then
        return nil
    end

    local name = node_text(bufnr, ident) or ""
    if not function_wrapper_enabled(opts, name) then
        return nil
    end

    local code = call:parent()
    if not code or code:type() ~= "embedded_code" then
        return nil
    end

    local reveal_range = range_from_node(code)
    local content_range = range_from_node(content)
    if reveal_range.start_row ~= content_range.start_row then
        return nil
    end

    local prefix_range = {
        start_row = reveal_range.start_row,
        start_col = reveal_range.start_col,
        end_row = content_range.start_row,
        end_col = content_range.start_col + 1,
    }
    local suffix_range = {
        start_row = reveal_range.end_row,
        start_col = math.max(reveal_range.end_col - 1, 0),
        end_row = reveal_range.end_row,
        end_col = reveal_range.end_col,
    }

    return {
        wrapper_part(
            bufnr,
            prefix_range,
            reveal_range,
            range_text(bufnr, prefix_range),
            name,
            "prefix"
        ),
        wrapper_part(
            bufnr,
            suffix_range,
            reveal_range,
            range_text(bufnr, suffix_range),
            name,
            "suffix"
        ),
    }
end

return M
