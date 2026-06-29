local M = {}

-- Enrich static import records with the definitions they expose. This runs
-- after every file has been scanned, because re-exports and wildcard/module
-- aliases can only be resolved from the aggregate project view.

local function add_unique(list, seen, key, item)
    if not key or seen[key] then
        return
    end

    seen[key] = true
    list[#list + 1] = item
end

local function expand_imported_definition(out, seen, import, name, definition)
    add_unique(out.imported_bindings, seen.imported_bindings, name, {
        name = name,
        imported_name = name,
        spec = import.spec,
        path = import.path,
        kind = definition.kind == "function" and "function" or "member",
        source = import.source,
        definition = definition.source,
        signature = definition.signature,
        parameters = vim.deepcopy(definition.parameters or {}),
        wildcard = import.kind == "wildcard_import" or nil,
    })
end

local function expand_imported_binding(out, seen, import, name, binding)
    add_unique(out.imported_bindings, seen.imported_bindings, name, {
        name = name,
        imported_name = binding.imported_name or name,
        spec = import.spec,
        path = binding.path or import.path,
        kind = binding.kind == "function" and "function" or "member",
        source = import.source,
        definition = binding.definition,
        signature = binding.signature,
        parameters = vim.deepcopy(binding.parameters or {}),
        wildcard = import.kind == "wildcard_import" or nil,
        reexported = true,
    })
end

local function imported_definition(path, name, out)
    return path
        and out.definitions_by_file[path]
        and out.definitions_by_file[path][name]
end

local function imported_definitions(path, out)
    return path and out.definitions_by_file[path] or nil
end

local function imported_binding_lookup(out)
    local by_file = {}
    for _, item in ipairs(out.imported_bindings or {}) do
        local source_path = item.source and item.source.path
        if source_path and item.name then
            by_file[source_path] = by_file[source_path] or {}
            by_file[source_path][item.name] = item
        end
    end
    return by_file
end

local function imported_bindings_for(path, lookup)
    return path and lookup[path] or nil
end

local function exported_imported_binding(path, name, lookup)
    local by_name = imported_bindings_for(path, lookup)
    local item = by_name and by_name[name] or nil
    if item and item.definition then
        return item
    end
end

local function assign_imported_definition(imported, definition)
    if not definition then
        return false
    end

    local next_kind = definition.kind
    local next_definition = definition.source
    local next_signature = definition.signature
    local next_parameters = vim.deepcopy(definition.parameters or {})
    local changed = imported.kind ~= next_kind
        or vim.inspect(imported.definition) ~= vim.inspect(next_definition)
        or imported.signature ~= next_signature
        or vim.inspect(imported.parameters or {})
            ~= vim.inspect(next_parameters)

    imported.kind = next_kind
    imported.definition = next_definition
    imported.signature = next_signature
    imported.parameters = next_parameters
    return changed
end

local function assign_imported_binding(imported, binding)
    if not (binding and binding.definition) then
        return false
    end

    local next_kind = binding.kind == "function" and "function" or "member"
    local next_definition = binding.definition
    local next_signature = binding.signature
    local next_parameters = vim.deepcopy(binding.parameters or {})
    local next_imported_name = binding.imported_name or imported.imported_name
    local changed = imported.kind ~= next_kind
        or vim.inspect(imported.definition) ~= vim.inspect(next_definition)
        or imported.signature ~= next_signature
        or vim.inspect(imported.parameters or {}) ~= vim.inspect(
            next_parameters
        )
        or imported.imported_name ~= next_imported_name
        or imported.reexported ~= true

    imported.kind = next_kind
    imported.imported_name = next_imported_name
    imported.definition = next_definition
    imported.signature = next_signature
    imported.parameters = next_parameters
    imported.reexported = true
    return changed
end

local function enrich_direct_import(imported, out, lookup)
    local definition =
        imported_definition(imported.path, imported.imported_name, out)
    if definition then
        return assign_imported_definition(imported, definition)
    end

    return assign_imported_binding(
        imported,
        exported_imported_binding(imported.path, imported.imported_name, lookup)
    )
end

local function enrich_direct_imports(out)
    local limit = #(out.imported_bindings or {}) + 1
    local changed_any = false

    -- Re-export chains may need several passes, but a fixed upper bound keeps a
    -- cyclic import graph from looping forever.
    for _ = 1, limit do
        local changed = false
        local lookup = imported_binding_lookup(out)
        for _, imported in ipairs(out.imported_bindings or {}) do
            changed = enrich_direct_import(imported, out, lookup) or changed
        end
        changed_any = changed_any or changed
        if not changed then
            break
        end
    end

    return changed_any
end

local function enrich_wildcard_import(import, out, seen)
    for name, definition in pairs(imported_definitions(import.path, out) or {}) do
        expand_imported_definition(out, seen, import, name, definition)
    end

    for name, binding in
        pairs(
            imported_bindings_for(import.path, imported_binding_lookup(out))
                or {}
        )
    do
        if binding.definition then
            expand_imported_binding(out, seen, import, name, binding)
        end
    end
end

local function enrich_module_alias(alias, out, seen)
    for name, definition in pairs(imported_definitions(alias.path, out) or {}) do
        local word = alias.name .. "." .. name
        add_unique(out.imported_bindings, seen.imported_bindings, word, {
            name = word,
            imported_name = name,
            module = alias.name,
            spec = alias.spec,
            path = alias.path,
            kind = definition.kind == "function" and "function" or "member",
            source = alias.source,
            definition = definition.source,
            signature = definition.signature,
            parameters = vim.deepcopy(definition.parameters or {}),
        })
    end

    for name, binding in
        pairs(
            imported_bindings_for(alias.path, imported_binding_lookup(out))
                or {}
        )
    do
        if binding.definition then
            local word = alias.name .. "." .. name
            add_unique(out.imported_bindings, seen.imported_bindings, word, {
                name = word,
                imported_name = binding.imported_name or name,
                module = alias.name,
                spec = alias.spec,
                path = binding.path or alias.path,
                kind = binding.kind == "function" and "function" or "member",
                source = alias.source,
                definition = binding.definition,
                signature = binding.signature,
                parameters = vim.deepcopy(binding.parameters or {}),
                reexported = true,
            })
        end
    end
end

function M.enrich(out, seen)
    enrich_direct_imports(out)

    for _, import in ipairs(out.wildcard_imports) do
        enrich_wildcard_import(import, out, seen)
    end

    for _, alias in ipairs(out.module_aliases) do
        enrich_module_alias(alias, out, seen)
    end

    enrich_direct_imports(out)
end

return M
