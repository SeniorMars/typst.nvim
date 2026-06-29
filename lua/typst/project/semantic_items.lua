local util = require("typst.core.util")

local M = {}

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    value = vim.trim(value)
    if value == "" then
        return nil
    end

    return value
end

local function source_location(path, row, col)
    return {
        path = path,
        lnum = row,
        col = col or 1,
    }
end

local function add_unique(list, seen, key, item)
    if not key or seen[key] then
        return
    end

    seen[key] = true
    list[#list + 1] = item
end

local function list_key(item)
    local source = item.source or {}
    return ("%s\n%s\n%s\n%s"):format(
        item.name or item.word or item.spec or item.kind or "",
        source.path or "",
        source.lnum or "",
        source.col or ""
    )
end

local symbol_kind_names = nil

local function symbol_kind_name(kind)
    if not symbol_kind_names then
        symbol_kind_names = {}
        for name, value in pairs(vim.lsp.protocol.SymbolKind or {}) do
            if type(value) == "number" then
                symbol_kind_names[value] = name:lower()
            end
        end
    end

    return symbol_kind_names[kind] or "symbol"
end

function M.definition_kind(kind)
    local kinds = vim.lsp.protocol.SymbolKind or {}
    if
        kind == kinds.Function
        or kind == kinds.Method
        or kind == kinds.Constructor
    then
        return "function"
    end
    if kind == kinds.Variable then
        return "local"
    end
    if kind == kinds.Constant then
        return "constant"
    end
    if kind == kinds.Field or kind == kinds.Property then
        return "field"
    end
    if
        kind == kinds.Class
        or kind == kinds.Struct
        or kind == kinds.Interface
        or kind == kinds.Enum
    then
        return "type"
    end
    if
        kind == kinds.Module
        or kind == kinds.Namespace
        or kind == kinds.Package
        or kind == kinds.File
    then
        return "module"
    end
    if kind == kinds.String then
        return nil
    end
    return "symbol"
end

local function semantic_heading_kind(kind)
    return kind == (vim.lsp.protocol.SymbolKind or {}).String
end

local function add_definition(out, seen, symbol, file)
    local name = trim(symbol.name)
    local kind = M.definition_kind(symbol.kind)
    if not name or not kind or not file then
        return
    end

    local key = file .. "\n" .. name
    if seen.definitions[key] then
        return
    end

    local item = {
        name = name,
        kind = kind,
        symbol_kind = symbol.kind,
        symbol_kind_name = symbol_kind_name(symbol.kind),
        semantic = true,
        source_kind = "tinymist",
        provider = "tinymist",
        source = source_location(file, symbol.lnum or 1, symbol.col or 1),
    }

    add_unique(out.definitions, seen.definitions, key, item)
    out.definitions_by_file[file] = out.definitions_by_file[file] or {}
    out.definitions_by_file[file][name] = item
end

function M.add_reference(out, seen, name, location)
    name = trim(name)
    local file = location and location.file and util.normalize(location.file)
        or nil
    if not name or not file then
        return
    end

    local item = {
        name = name,
        kind = "reference",
        reference_style = "semantic",
        reference_target = "definition",
        reference_target_name = name,
        semantic = true,
        source_kind = "tinymist",
        provider = "tinymist",
        source = source_location(file, location.lnum or 1, location.col or 1),
    }

    add_unique(out.references, seen.references, list_key(item), item)
end

function M.add_symbol(out, seen, symbol, fallback_path, helpers)
    local file = symbol.file or fallback_path
    file = file and util.normalize(file) or nil
    if not file or not symbol.name then
        return
    end

    if semantic_heading_kind(symbol.kind) and helpers.add_heading then
        helpers.add_heading(
            out,
            seen,
            file,
            symbol.lnum or 1,
            symbol.col or 1,
            symbol.level or 1,
            symbol.name,
            "tinymist"
        )
    end

    add_definition(out, seen, symbol, file)
end

return M
