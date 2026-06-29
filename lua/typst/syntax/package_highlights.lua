local config = require("typst.config")
local edit_ts = require("typst.core.treesitter")
local index = require("typst.index")
local lexical = require("typst.syntax.lexical")
local package_extensions = require("typst.syntax.package_extensions")

-- Package-extension highlighting.
--
-- The candidates come from the project import graph, not from every known
-- package member. Tree-sitter gives precise identifier ranges when available;
-- the lexical fallback keeps the feature usable when the parser is missing.
local M = {}

local namespace = vim.api.nvim_create_namespace("typst.nvim.syntax.packages")
local default_highlight_defined = false
local buffer_lines

local function same_package(item, extension)
    return package_extensions.package_key(item.spec) == extension.package_key
end

local function add_name(names, text, role, extension)
    if type(text) ~= "string" or text == "" or names[text] then
        return
    end

    names[text] = {
        text = text,
        role = role,
        extension = extension,
    }
end

local function names_for_extension(collected, extension)
    local names = {}

    -- Highlight only names the project imported or aliased. Otherwise a package
    -- extension could color unrelated identifiers that merely share a member
    -- name with a supported package.
    for _, imported in ipairs(collected.imported_bindings or {}) do
        if same_package(imported, extension) then
            add_name(names, imported.name, "member", extension)
            for _, member in ipairs(extension.members) do
                add_name(
                    names,
                    imported.name .. "." .. member,
                    "member",
                    extension
                )
            end
        end
    end

    for _, alias in ipairs(collected.module_aliases or {}) do
        if same_package(alias, extension) then
            add_name(names, alias.name, "module", extension)
            for _, member in ipairs(extension.members) do
                add_name(
                    names,
                    alias.name .. "." .. member,
                    "member",
                    extension
                )
            end
        end
    end

    local sorted = vim.tbl_values(names)
    table.sort(sorted, function(a, b)
        if #a.text == #b.text then
            return a.text < b.text
        end
        return #a.text > #b.text
    end)
    return sorted
end

local function is_name_char(char)
    return type(char) == "string" and char:match("[%w_%.%-]") ~= nil
end

local function has_name_boundary(line, start_col, end_col)
    local before = start_col > 1 and line:sub(start_col - 1, start_col - 1)
        or nil
    local after = end_col < #line and line:sub(end_col + 1, end_col + 1) or nil
    return not is_name_char(before) and not is_name_char(after)
end

local semantic_symbol_types = {
    ["class"] = true,
    enumMember = true,
    ["function"] = true,
    macro = true,
    method = true,
    namespace = true,
    property = true,
    struct = true,
    ["type"] = true,
    variable = true,
}

local function add_match(matches, item, row, start_col, end_col, evidence)
    local extension = item.extension
    matches[#matches + 1] = {
        name = item.text,
        role = item.role,
        package = extension.package,
        package_key = extension.package_key,
        extension = extension.name,
        capture = extension.capture,
        hl_group = extension.highlight_group,
        priority = extension.priority,
        range = {
            row = row,
            col = start_col - 1,
            end_row = row,
            end_col = end_col,
        },
        semantic_token = evidence == "semantic_token" or nil,
    }
end

local function name_lookup(names)
    local lookup = {}
    for _, item in ipairs(names) do
        if lookup[item.text] == nil then
            lookup[item.text] = item
        end
    end
    return lookup
end

local function token_type(token)
    if type(token) ~= "table" then
        return nil
    end
    return token.type or token.token_type or token.tokenType or token[1]
end

local function token_range(token, fallback_len)
    if type(token) ~= "table" then
        return nil, nil
    end

    local start_col = token.start_col or token.col or token.start
    local end_col = token.end_col or token["end"]
    if type(token.range) == "table" then
        local range = token.range
        local start = range.start or {}
        local finish = range["end"] or {}
        start_col = start_col or start.character
        end_col = end_col or finish.character
    end
    if type(end_col) ~= "number" and type(start_col) == "number" then
        end_col = start_col
            + (tonumber(token.length or token.len) or fallback_len)
    end
    return tonumber(start_col), tonumber(end_col)
end

local function semantic_token_result(tokens, candidate)
    if type(tokens) ~= "table" then
        return nil
    end

    for _, token in ipairs(tokens) do
        local start_col, end_col = token_range(token, #candidate.text)
        if
            start_col
            and end_col
            and candidate.col >= start_col
            and candidate.end_col <= end_col
        then
            local kind = token_type(token)
            if type(kind) == "string" then
                return semantic_symbol_types[kind] == true
            end
        end
    end
end

local function builtin_semantic_tokens(bufnr, row, col)
    local semantic = vim.lsp and vim.lsp.semantic_tokens or nil
    if not semantic or type(semantic.get_at_pos) ~= "function" then
        return nil
    end

    local ok, tokens = pcall(semantic.get_at_pos, bufnr, row, col)
    if ok and type(tokens) == "table" then
        return tokens
    end
end

local function semantic_token_allows(bufnr, candidate, opts)
    opts = opts or {}
    if opts.semantic_tokens == false then
        return nil
    end

    if type(opts.semantic_tokens) == "function" then
        local ok, allowed = pcall(opts.semantic_tokens, bufnr, candidate)
        if ok and type(allowed) == "boolean" then
            return allowed
        end
    elseif type(opts.semantic_tokens) == "table" then
        local tokens = opts.semantic_tokens[candidate.row]
            or opts.semantic_tokens[tostring(candidate.row)]
            or opts.semantic_tokens
        local result = semantic_token_result(tokens, candidate)
        if result ~= nil then
            return result
        end
    end

    local result = semantic_token_result(
        builtin_semantic_tokens(bufnr, candidate.row, candidate.col),
        candidate
    )
    if result ~= nil then
        return result
    end
end

local function candidate_allowed(bufnr, candidate, opts)
    opts = opts or {}
    local syntax = config.unsafe_get().syntax or {}
    local proof = opts.semantic_proof
        or opts.package_semantic_proof
        or syntax.package_semantic_proof
        or "auto"
    if proof == "off" then
        return true, nil
    end

    local allowed = semantic_token_allows(bufnr, candidate, opts)
    if allowed == false then
        return false, nil
    end
    -- Package extension names can collide with ordinary identifiers. Semantic
    -- tokens, when available, are used as proof before applying special package
    -- highlights in strict mode.
    if proof == "required" then
        return allowed == true, allowed == true and "semantic_token" or nil
    end
    return true, allowed == true and "semantic_token" or nil
end

local function scan_line(line, masked_line, row, names, matches, bufnr, opts)
    local index = 1
    while index <= #masked_line do
        local char = masked_line:sub(index, index)
        if is_name_char(char) then
            local start_col = index
            repeat
                index = index + 1
                char = masked_line:sub(index, index)
            until index > #masked_line or not is_name_char(char)

            local end_col = index - 1
            local name = masked_line:sub(start_col, end_col)
            local item = names[name]
            if item and has_name_boundary(line, start_col, end_col) then
                local allowed, evidence = candidate_allowed(bufnr, {
                    text = name,
                    row = row,
                    col = start_col - 1,
                    end_col = end_col,
                }, opts)
                if allowed then
                    add_match(matches, item, row, start_col, end_col, evidence)
                end
            end
        else
            index = index + 1
        end
    end
end

local treesitter_code_ancestors = {
    arguments = true,
    closure = true,
    embedded_code = true,
    for_loop = true,
    function_call = true,
    let_binding = true,
    math = true,
    module_import = true,
    module_include = true,
    set_rule = true,
    show_rule = true,
    while_loop = true,
}

local function treesitter_code_candidate(node)
    local parent = node:parent()
    while parent do
        if treesitter_code_ancestors[parent:type()] then
            return true
        end
        parent = parent:parent()
    end
    return false
end

local function treesitter_candidates(bufnr)
    local root = edit_ts.root(bufnr)
    if not root then
        return nil
    end

    local candidates = {}
    local function add(node)
        local text = vim.treesitter.get_node_text(node, bufnr)
        if type(text) ~= "string" or text == "" then
            return
        end

        local start_row, start_col, end_row, end_col = node:range()
        if start_row ~= end_row then
            return
        end

        candidates[#candidates + 1] = {
            text = text,
            row = start_row,
            col = start_col,
            end_col = end_col,
        }
    end

    local function walk(node)
        local node_type = node:type()
        if node_type == "field_access" then
            if treesitter_code_candidate(node) then
                add(node)
            end
            return
        end
        if node_type == "identifier" then
            if treesitter_code_candidate(node) then
                add(node)
            end
            return
        end

        for child in node:iter_children() do
            walk(child)
        end
    end

    walk(root)
    return candidates
end

local function scan_treesitter_candidates(bufnr, names, matches, opts)
    local candidates = treesitter_candidates(bufnr)
    if not candidates then
        return false
    end

    for _, candidate in ipairs(candidates) do
        local item = names[candidate.text]
        if item then
            local allowed, evidence = candidate_allowed(bufnr, candidate, opts)
            if allowed then
                add_match(
                    matches,
                    item,
                    candidate.row,
                    candidate.col + 1,
                    candidate.end_col,
                    evidence
                )
            end
        end
    end

    return true
end

local lexical_line_keywords = {
    ["for"] = true,
    import = true,
    include = true,
    let = true,
    set = true,
    show = true,
    ["while"] = true,
}

local function copy_span(source, target, start_col, end_col)
    for index = start_col, end_col do
        target[index] = source:sub(index, index)
    end
end

local function lexical_code_mask(masked_line)
    local out = {}
    for index = 1, #masked_line do
        out[index] = " "
    end

    local index = 1
    while index <= #masked_line do
        local marker = masked_line:find("#", index, true)
        if not marker then
            break
        end

        local start_col = marker + 1
        while masked_line:sub(start_col, start_col):match("%s") do
            start_col = start_col + 1
        end

        local name_end = start_col - 1
        while
            name_end + 1 <= #masked_line
            and is_name_char(masked_line:sub(name_end + 1, name_end + 1))
        do
            name_end = name_end + 1
        end

        local keyword = masked_line:sub(start_col, name_end)
        if lexical_line_keywords[keyword] then
            -- Import/selectors and declarations can introduce package aliases
            -- away from the initial #keyword token, so keep the whole code line.
            copy_span(masked_line, out, start_col, #masked_line)
            index = #masked_line + 1
        elseif name_end >= start_col then
            -- For markup fallback, only the expression introduced by # is a
            -- package candidate. Scanning the rest of the prose would color
            -- ordinary words that happen to match imported package members.
            copy_span(masked_line, out, start_col, name_end)
            index = name_end + 1
        else
            index = marker + 1
        end
    end

    return table.concat(out)
end

local function scan_lexical(bufnr, names, matches, opts)
    local lines = buffer_lines(bufnr)
    local masked_lines = lexical.mask_lines(lines, {
        strings = true,
        raw = true,
        comments = true,
    })
    for row, line in ipairs(lines) do
        local masked_line = masked_lines[row] or ""
        scan_line(
            line,
            lexical_code_mask(masked_line),
            row - 1,
            names,
            matches,
            bufnr,
            opts
        )
    end
end

function buffer_lines(bufnr)
    if
        vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
    then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    return {}
end

local function define_default_highlight()
    if default_highlight_defined then
        return
    end

    pcall(vim.api.nvim_set_hl, 0, "TypstPackageSpecial", {
        link = "Special",
        default = true,
    })
    pcall(vim.api.nvim_set_hl, 0, "TypstPackageCetz", {
        link = "TypstPackageSpecial",
        default = true,
    })
    default_highlight_defined = true
end

function M.matches(opts)
    opts = opts or {}
    local syntax = config.unsafe_get().syntax or {}
    if not syntax.package_extensions then
        return {}
    end

    local bufnr = package_extensions.normalize_bufnr(opts.bufnr)
    local project = package_extensions.project_for({
        bufnr = bufnr,
        project = opts.project,
    })
    if not project then
        return {}
    end

    local collected = opts.collected or index.collect({ project = project })
    if not collected then
        return {}
    end

    local all_names = {}
    for _, extension in
        ipairs(
            package_extensions.list({ project = project, collected = collected })
        )
    do
        vim.list_extend(all_names, names_for_extension(collected, extension))
    end

    if #all_names == 0 then
        return {}
    end

    local names = name_lookup(all_names)
    local matches = {}
    -- Lexical scanning is a fallback, not a second pass. Running both would
    -- create duplicate extmarks and reintroduce matches inside parser-known
    -- syntax that Tree-sitter intentionally skipped.
    if not scan_treesitter_candidates(bufnr, names, matches, opts) then
        scan_lexical(bufnr, names, matches, opts)
    end

    table.sort(matches, function(a, b)
        if a.range.row == b.range.row then
            return a.range.col < b.range.col
        end
        return a.range.row < b.range.row
    end)
    return matches
end

function M.refresh(bufnr)
    bufnr = package_extensions.normalize_bufnr(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

    local matches = M.matches({ bufnr = bufnr })
    if #matches == 0 then
        return matches
    end

    define_default_highlight()
    for _, match in ipairs(matches) do
        vim.api.nvim_buf_set_extmark(
            bufnr,
            namespace,
            match.range.row,
            match.range.col,
            {
                end_row = match.range.end_row,
                end_col = match.range.end_col,
                hl_group = match.hl_group,
                priority = match.priority,
                strict = false,
            }
        )
    end
    return matches
end

function M.clear(bufnr)
    bufnr = package_extensions.normalize_bufnr(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    end
end

function M.apply(bufnr)
    return M.refresh(bufnr)
end

function M.namespace()
    return namespace
end

return M
