local config = require("typst.config")

local M = {}

local user_kinds = {
    "all",
    "toc",
    "headings",
    "figures",
    "tables",
    "equations",
    "labels",
    "references",
    "citations",
    "bibliography",
    "imports",
    "files",
    "todos",
    "definitions",
}

local canonical_order = {
    heading = 1,
    figure = 2,
    table = 3,
    equation = 4,
    label = 5,
    reference = 6,
    citation = 7,
    bibliography = 8,
    import = 9,
    file = 10,
    todo = 11,
    definition = 12,
    toc = 13,
}

local toc_model_kinds = {
    heading = true,
    figure = true,
    table = true,
    equation = true,
    label = true,
    reference = true,
    citation = true,
    bibliography = true,
    import = true,
    file = true,
    todo = true,
    definition = true,
}

local kind_aliases = {
    all = "all",
    toc = "toc",
    table_of_contents = "toc",
    heading = "heading",
    headings = "heading",
    figure = "figure",
    figures = "figure",
    table = "table",
    tables = "table",
    equation = "equation",
    equations = "equation",
    label = "label",
    labels = "label",
    reference = "reference",
    references = "reference",
    citation = "citation",
    citations = "citation",
    bibliography = "bibliography",
    bibliographies = "bibliography",
    bib = "bibliography",
    bibs = "bibliography",
    import = "import",
    imports = "import",
    file = "file",
    files = "file",
    path = "file",
    paths = "file",
    todo = "todo",
    todos = "todo",
    task = "todo",
    tasks = "todo",
    definition = "definition",
    definitions = "definition",
    symbol = "definition",
    symbols = "definition",
}

local function all_kinds()
    local kinds = {}
    for kind in pairs(toc_model_kinds) do
        kinds[kind] = true
    end
    kinds.toc = true
    kinds._all = true
    return kinds
end

local function split_kind_string(value)
    local parts = {}
    for part in value:gmatch("[^,%s]+") do
        parts[#parts + 1] = part
    end
    return parts
end

function M.names()
    return vim.deepcopy(user_kinds)
end

function M.order(kind)
    return canonical_order[kind] or 99
end

function M.is_toc_model(kind)
    return toc_model_kinds[kind] == true
end

function M.normalize(opts)
    opts = opts or {}
    local value = opts.kinds
        or opts.kind
        or (config.unsafe_get().picker or {}).kinds
        or "all"
    local raw = {}

    if type(value) == "string" then
        raw = split_kind_string(value)
    elseif type(value) == "table" then
        for _, item in ipairs(value) do
            if type(item) == "string" then
                vim.list_extend(raw, split_kind_string(item))
            end
        end
    end

    if #raw == 0 then
        return all_kinds()
    end

    local kinds = {}
    for _, item in ipairs(raw) do
        local canonical = kind_aliases[item]
        if canonical == "all" then
            return all_kinds()
        end
        if canonical then
            kinds[canonical] = true
        elseif item ~= "" then
            kinds[item] = true
        end
    end

    if next(kinds) == nil then
        return all_kinds()
    end
    return kinds
end

function M.wants_toc_layers(kinds)
    if kinds.toc or kinds._all then
        return true
    end

    for kind in pairs(kinds) do
        if kind ~= "heading" and kind ~= "_all" then
            return true
        end
    end

    return false
end

return M
