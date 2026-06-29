local tree = require("typst.conceal.shadow_tree")
local telemetry = require("typst.core.telemetry")

local M = {}

local shadow_cache = {}
local lexical_scope_cache = {}

local function scope_cache_for(bufnr, signature)
    local entry = lexical_scope_cache[bufnr]
    if not entry or entry.signature ~= signature then
        entry = {
            signature = signature,
            scopes = {},
        }
        lexical_scope_cache[bufnr] = entry
    end

    return entry.scopes
end

local function cached_lexical_scope(bufnr, root, signature, node)
    local cache = scope_cache_for(bufnr, signature)
    local key = tree.node_id(node) or tostring(node)
    if cache[key] ~= nil then
        return cache[key] or nil
    end

    local scope = tree.lexical_scope(node) or tree.range_from_node(root)
    cache[key] = scope or false
    return scope
end

local function collect_shadowed_symbols(bufnr, root, signature)
    local shadows = {
        names = {},
        wildcards = {},
    }

    local function add_binding(name, node, scope)
        if type(name) == "string" and name ~= "" then
            local node_range = tree.range_from_node(node)
            shadows.names[name] = shadows.names[name] or {}
            shadows.names[name][#shadows.names[name] + 1] = {
                start_row = node_range.start_row,
                start_col = node_range.start_col,
                scope = scope
                    or cached_lexical_scope(bufnr, root, signature, node)
                    or tree.range_from_node(root),
            }
        end
    end

    local function add_function_parameters(node)
        local body_scope = tree.let_body_scope(node)
        if not body_scope then
            return
        end

        local parameters = tree.first_child(node, "parameters")
        if not parameters then
            return
        end

        for _, child in ipairs(tree.children(parameters)) do
            local child_type = child:type()
            if child_type == "identifier" then
                add_binding(tree.node_text(bufnr, child), child, body_scope)
            elseif
                child_type == "named_parameter"
                or child_type == "sink_parameter"
            then
                local name = tree.first_child(child, "identifier")
                if name then
                    add_binding(tree.node_text(bufnr, name), name, body_scope)
                end
            end
        end
    end

    local function add_wildcard(node)
        local node_range = tree.range_from_node(node)
        shadows.wildcards[#shadows.wildcards + 1] = {
            start_row = node_range.start_row,
            start_col = node_range.start_col,
            scope = cached_lexical_scope(bufnr, root, signature, node)
                or tree.range_from_node(root),
        }
    end

    local function walk(node)
        local node_type = node:type()
        if node_type == "let_binding" then
            add_binding(tree.let_binding_name(bufnr, node), node)
            add_function_parameters(node)
        elseif node_type == "module_import" or node_type == "import_item" then
            add_binding(tree.import_binding_name(bufnr, node), node)
        elseif node_type == "wildcard_import" then
            add_wildcard(node)
        elseif node_type == "import_list" then
            for _, child in ipairs(tree.children(node)) do
                local child_type = child:type()
                if child_type == "import_item" then
                    add_binding(tree.import_binding_name(bufnr, child), child)
                elseif child_type == "wildcard_import" then
                    add_wildcard(child)
                end
            end
        end

        for _, child in ipairs(tree.children(node)) do
            walk(child)
        end
    end

    walk(root)
    return shadows
end

local function shadow_counts(shadows)
    local name_bindings = 0
    local unique_names = 0
    for _, bindings in pairs((shadows and shadows.names) or {}) do
        unique_names = unique_names + 1
        name_bindings = name_bindings + #(bindings or {})
    end
    return {
        names = unique_names,
        name_bindings = name_bindings,
        wildcards = #((shadows and shadows.wildcards) or {}),
    }
end

local function shadowed_symbols(bufnr, root)
    local signature = tree.syntax_signature(bufnr, root)
    local entry = shadow_cache[bufnr]
    if entry and entry.signature == signature then
        telemetry.record(
            "conceal.shadows.cache_hit",
            0,
            shadow_counts(entry.shadows)
        )
        return entry.shadows
    end

    local started = telemetry.start()
    local shadows = collect_shadowed_symbols(bufnr, root, signature)
    telemetry.finish("conceal.shadows.collect", started, shadow_counts(shadows))
    telemetry.record("conceal.shadows.cache_miss", 0, shadow_counts(shadows))
    shadow_cache[bufnr] = {
        signature = signature,
        shadows = shadows,
    }
    return shadows
end

local function binding_applies(binding, range)
    return tree.position_leq(
        binding.start_row,
        binding.start_col,
        range.start_row,
        range.start_col
    ) and tree.range_contains(
        binding.scope,
        range.start_row,
        range.start_col
    )
end

local function has_applicable_binding(bindings, range)
    for _, binding in ipairs(bindings or {}) do
        if binding_applies(binding, range) then
            return true
        end
    end
    return false
end

local function symbol_shadowed(name, explicit, shadows, range)
    if explicit then
        return false
    end

    for _, wildcard in ipairs(shadows.wildcards or {}) do
        if binding_applies(wildcard, range) then
            return true
        end
    end

    local root_name = name:match("^([^%.]+)") or name
    return has_applicable_binding(shadows.names[name], range)
        or has_applicable_binding(shadows.names[root_name], range)
end

function M.collect(bufnr, root)
    return shadowed_symbols(bufnr, root)
end

function M.symbol_shadowed(name, explicit, shadows, range)
    return symbol_shadowed(name, explicit, shadows, range)
end

function M.forget(bufnr)
    shadow_cache[bufnr] = nil
    lexical_scope_cache[bufnr] = nil
end

---Clear all cached shadow state.
function M.reset()
    shadow_cache = {}
    lexical_scope_cache = {}
end

return M
