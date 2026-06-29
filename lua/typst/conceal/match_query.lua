local config = require("typst.config")
local emoji = require("typst.conceal.emoji")
local conceal_util = require("typst.conceal.util")
local math_rules = require("typst.conceal.math")
local metadata = require("typst.metadata")
local rules = require("typst.conceal.rules")
local shadows = require("typst.conceal.shadows")
local syntax = require("typst.conceal.syntax")
local symbols = require("typst.conceal.symbols")
local telemetry = require("typst.core.telemetry")
local ts = require("typst.core.treesitter")

local M = {}

local EMPTY_CUSTOM = {}

local collect_error_ranges = conceal_util.collect_error_ranges
local intersects_error_range = conceal_util.intersects_error_range
local line_range = conceal_util.line_range
local overlaps = conceal_util.overlaps
local range_from_node = conceal_util.range_from_node
local range_size = conceal_util.range_size
local display_safe = conceal_util.display_safe

local function conceal_config()
    return config.unsafe_get().conceal
end

local cached_query = nil

local function conceal_query()
    if cached_query then
        return cached_query
    end

    local ok, query = pcall(vim.treesitter.query.get, "typst", "conceal")
    if ok and query then
        cached_query = query
        return query
    end
end

---Filter overlapping matches by preferring larger spans first.
---@param matches table[] # input unsorted matches
---@return table[] # overlap-filtered matches
function M.filter_overlaps(matches)
    table.sort(matches, function(left, right)
        if left.source.start_row ~= right.source.start_row then
            return left.source.start_row < right.source.start_row
        end
        if left.source.start_col ~= right.source.start_col then
            return left.source.start_col < right.source.start_col
        end
        return range_size(left.source) > range_size(right.source)
    end)

    local filtered = {}
    local last = nil
    for _, match in ipairs(matches) do
        if not last or not overlaps(match.source, last.source) then
            filtered[#filtered + 1] = match
            last = match
        end
    end

    return filtered
end

local function add_match(matches, match)
    if not match then
        return
    end
    if match.source then
        matches[#matches + 1] = match
        return
    end
    for _, item in ipairs(match) do
        matches[#matches + 1] = item
    end
end

local function row_intersects_error(row, error_ranges)
    for _, error_range in ipairs(error_ranges) do
        if row >= error_range.start_row and row < error_range.end_row then
            return true
        end
    end
    return false
end

local function add_error_recovery_math(
    bufnr,
    matches,
    opts,
    start_row,
    end_row,
    error_ranges
)
    if #error_ranges == 0 or not opts.categories.math_symbols then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
    for offset, line in ipairs(lines) do
        local row = start_row + offset - 1
        if not row_intersects_error(row, error_ranges) then
            local index = 1
            while index <= #line do
                local open_col = line:find("$", index, true)
                local close_col = open_col
                        and line:find("$", open_col + 1, true)
                    or nil
                if not (open_col and close_col) then
                    break
                end

                local body = line:sub(open_col + 1, close_col - 1)
                for start_offset, name in body:gmatch("()([%a_][%w_%.]*)") do
                    local record = metadata.symbol(name)
                    if record and display_safe(record, opts) then
                        local start_col = open_col + start_offset - 1
                        local source_range = {
                            start_row = row,
                            start_col = start_col,
                            end_row = row,
                            end_col = start_col + #name,
                        }
                        add_match(
                            matches,
                            syntax.range_match(
                                bufnr,
                                source_range,
                                source_range,
                                opts,
                                "math_symbols",
                                record.glyph,
                                record.kind or "symbol",
                                record.symbol_id or ("sym." .. name),
                                {
                                    symbol_id = record.symbol_id,
                                    record = record,
                                }
                            )
                        )
                    end
                end

                index = close_col + 1
            end
        end
    end
end

local function register_builtin_rules()
    for _, rule in ipairs(rules.registered("conceal.symbol")) do
        if rule.name == "math_symbols" then
            return
        end
    end

    rules.register({
        name = "math_symbols",
        capture = "conceal.symbol",
        category = "math_symbols",
        priority = 100,
        resolve = function(ctx, node)
            return symbols.resolve(
                ctx.bufnr,
                node,
                ctx.opts,
                ctx.shadow_state,
                ctx.custom_math
            )
        end,
    })

    rules.register({
        name = "emoji",
        capture = "conceal.emoji",
        category = "emoji",
        priority = 100,
        resolve = function(ctx, node)
            return emoji.resolve(ctx.bufnr, node, ctx.opts)
        end,
    })

    rules.register({
        name = "math_delimiters",
        capture = "conceal.math_delimiter",
        category = "math_delimiters",
        priority = 100,
        resolve = function(ctx, node)
            return syntax.node(
                ctx.bufnr,
                node,
                ctx.opts,
                "math_delimiters",
                "",
                "math delimiter",
                "math delimiter"
            )
        end,
    })

    rules.register({
        name = "markup_delimiters",
        capture = "conceal.markup_delimiter",
        category = "markup_delimiters",
        priority = 100,
        resolve = function(ctx, node)
            local parent = node:parent()
            local parent_type = parent and parent:type() or "markup"
            return syntax.node(
                ctx.bufnr,
                node,
                ctx.opts,
                "markup_delimiters",
                "",
                "markup delimiter",
                ("%s delimiter"):format(parent_type),
                parent
            )
        end,
    })

    rules.register({
        name = "heading_markers",
        capture = "conceal.heading_marker",
        category = "headings",
        priority = 100,
        resolve = function(ctx, node)
            return syntax.node(
                ctx.bufnr,
                node,
                ctx.opts,
                "headings",
                "",
                "heading marker",
                "heading marker",
                node:parent()
            )
        end,
    })

    rules.register({
        name = "math_scripts",
        capture = "conceal.script",
        category = "math_scripts",
        priority = 100,
        resolve = function(ctx, node)
            return math_rules.resolve_scripts(ctx.bufnr, node, ctx.opts)
        end,
    })

    rules.register({
        name = "math_fonts",
        capture = "conceal.math_call",
        category = "math_fonts",
        priority = 120,
        resolve = function(ctx, node)
            return math_rules.resolve_font_call(ctx, node)
        end,
    })

    rules.register({
        name = "math_wrappers",
        capture = "conceal.math_call",
        category = "math_wrappers",
        priority = 100,
        resolve = function(ctx, node)
            return math_rules.resolve_wrapper_call(ctx, node)
        end,
    })

    rules.register({
        name = "math_operators",
        capture = "conceal.math_operator",
        category = "math_operators",
        priority = 100,
        resolve = function(ctx, node)
            return math_rules.resolve_operator(ctx.bufnr, node, ctx.opts)
        end,
    })

    rules.register({
        name = "list_markers",
        capture = "conceal.list_marker",
        category = "lists",
        priority = 100,
        resolve = function(ctx, node)
            return syntax.list_marker(ctx.bufnr, node, ctx.opts)
        end,
    })

    local function raw_delimiter(ctx, node)
        return syntax.node(
            ctx.bufnr,
            node,
            ctx.opts,
            "raw_blocks",
            "",
            "raw delimiter",
            "raw delimiter"
        )
    end

    rules.register({
        name = "raw_delimiters",
        capture = "conceal.raw_delimiter",
        category = "raw_blocks",
        priority = 100,
        resolve = raw_delimiter,
    })

    rules.register({
        name = "raw_block_fences",
        capture = "conceal.raw_block_fence",
        category = "raw_blocks",
        priority = 100,
        resolve = raw_delimiter,
    })

    rules.register({
        name = "raw_block_languages",
        capture = "conceal.raw_block_language",
        category = "raw_block_languages",
        priority = 100,
        resolve = function(ctx, node)
            return syntax.node(
                ctx.bufnr,
                node,
                ctx.opts,
                "raw_block_languages",
                "",
                "raw language tag",
                "raw language tag"
            )
        end,
    })

    rules.register({
        name = "label_delimiters",
        capture = "conceal.label_delimiter",
        category = "labels",
        priority = 100,
        resolve = function(ctx, node)
            return syntax.label_delimiters(ctx.bufnr, node, ctx.opts)
        end,
    })

    rules.register({
        name = "reference_markers",
        capture = "conceal.reference_marker",
        category = "reference_markers",
        priority = 100,
        resolve = function(ctx, node)
            local category = syntax.reference_category(ctx.opts)
            if not category then
                return nil
            end
            return syntax.node(
                ctx.bufnr,
                node,
                ctx.opts,
                category,
                "",
                "reference marker",
                "reference marker"
            )
        end,
    })

    rules.register({
        name = "function_wrappers",
        capture = "conceal.function_wrapper",
        category = "function_wrappers",
        priority = 100,
        resolve = function(ctx, node)
            return syntax.function_wrapper(ctx.bufnr, node, ctx.opts)
        end,
    })
end

register_builtin_rules()

function M.query(bufnr, start_row, end_row, custom_conceal)
    local root = ts.root(bufnr)
    local query = conceal_query()
    if not root or not query then
        return {}, false
    end

    local opts = conceal_config()
    local custom_math = (custom_conceal and custom_conceal.math) or EMPTY_CUSTOM
    local shadow_state = telemetry.time("conceal.shadows", function()
        return shadows.collect(bufnr, root)
    end)
    local query_range = line_range(start_row, end_row)
    local error_ranges = collect_error_ranges(root, {}, query_range)
    local matches = {}
    local ctx = {
        bufnr = bufnr,
        opts = opts,
        custom_math = custom_math,
        shadow_state = shadow_state,
    }

    telemetry.time("conceal.query", function()
        -- Skip captures inside syntax error ranges. Concealing malformed Typst can
        -- hide the text a user needs to repair and can make Tree-sitter ranges
        -- overlap in surprising ways.
        for id, node in query:iter_captures(root, bufnr, start_row, end_row) do
            local capture = query.captures[id]
            if
                not intersects_error_range(range_from_node(node), error_ranges)
            then
                add_match(matches, rules.resolve(capture, ctx, node))
            end
        end
    end)

    -- SeniorMars' parser can recover from an early malformed expression by
    -- wrapping later otherwise-valid lines in one ERROR node. Keep conceal off
    -- the malformed row, but still expose cheap math-symbol matches after it.
    add_error_recovery_math(
        bufnr,
        matches,
        opts,
        start_row,
        end_row,
        error_ranges
    )

    return M.filter_overlaps(matches)
end

function M.reset()
    cached_query = nil
end

return M
