local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local signature = "v1"
local children_calls = 0
local lexical_scope_calls = 0

local function make_node(kind, range, text, children)
    local node = {
        kind = kind,
        range = range,
        text = text,
        children = children or {},
    }

    function node:type()
        return self.kind
    end

    function node:parent()
        return self._parent
    end

    for _, child in ipairs(node.children) do
        child._parent = node
    end

    return node
end

local ident = make_node(
    "identifier",
    { start_row = 0, start_col = 2, end_row = 0, end_col = 7 },
    "alpha"
)
local binding = make_node(
    "let_binding",
    { start_row = 0, start_col = 2, end_row = 0, end_col = 20 },
    "#let alpha = 1",
    { ident }
)
local root_node = make_node(
    "source_file",
    { start_row = 0, start_col = 0, end_row = 20, end_col = 0 },
    "",
    { binding }
)

local fake_tree = {
    range_from_node = function(node)
        return node.range
    end,
    range_contains = function(range, row, col)
        return row >= range.start_row
            and row <= range.end_row
            and (row ~= range.start_row or col >= range.start_col)
            and (row ~= range.end_row or col <= range.end_col)
    end,
    node_id = function(node)
        return tostring(node)
    end,
    syntax_signature = function()
        return signature
    end,
    children = function(node)
        children_calls = children_calls + 1
        return node.children
    end,
    node_text = function(_, node)
        return node.text
    end,
    first_child = function(node, node_type)
        for _, child in ipairs(node.children) do
            if child:type() == node_type then
                return child
            end
        end
    end,
    import_binding_name = function(_, node)
        return node.text
    end,
    let_binding_name = function(_, node)
        for _, child in ipairs(node.children) do
            if child:type() == "identifier" then
                return child.text
            end
        end
    end,
    let_body_scope = function()
        return nil
    end,
    position_leq = function(left_row, left_col, right_row, right_col)
        return left_row < right_row
            or (left_row == right_row and left_col <= right_col)
    end,
    lexical_scope = function(node)
        lexical_scope_calls = lexical_scope_calls + 1
        local current = node and node:parent()
        while current and current:type() ~= "source_file" do
            current = current:parent()
        end
        return current and current.range or nil
    end,
}

package.loaded["typst.conceal.shadows"] = nil
package.loaded["typst.conceal.shadow_tree"] = fake_tree

local shadows = require("typst.conceal.shadows")
shadows.reset()

local first = shadows.collect(1, root_node)
local first_children_calls = children_calls
local first_lexical_scope_calls = lexical_scope_calls
assert(first.names.alpha, "first shadow collection should find alpha")

local second = shadows.collect(1, root_node)
assert(second == first, "same syntax signature should reuse shadow cache")
assert(
    children_calls == first_children_calls,
    "shadow cache hit should not rewalk the tree"
)
assert(
    lexical_scope_calls == first_lexical_scope_calls,
    "shadow cache hit should not recompute lexical scopes"
)

local after_binding = {
    start_row = 1,
    start_col = 0,
    end_row = 1,
    end_col = 5,
}
assert(
    shadows.symbol_shadowed("alpha", false, first, after_binding),
    "binding should shadow later implicit symbols in scope"
)
assert(
    not shadows.symbol_shadowed("alpha", true, first, after_binding),
    "explicit symbols should not be suppressed by local shadowing"
)
assert(
    not shadows.symbol_shadowed("beta", false, first, after_binding),
    "unrelated symbols should not be shadowed"
)

local before_binding = {
    start_row = 0,
    start_col = 0,
    end_row = 0,
    end_col = 1,
}
assert(
    not shadows.symbol_shadowed("alpha", false, first, before_binding),
    "binding should not shadow earlier positions"
)

signature = "v2"
local third = shadows.collect(1, root_node)
assert(third ~= first, "syntax signature change should invalidate cache")
assert(
    children_calls > first_children_calls,
    "signature change should rewalk the shadow tree"
)

local before_forget_calls = children_calls
shadows.forget(1)
local fourth = shadows.collect(1, root_node)
assert(fourth ~= third, "forget(bufnr) should drop cached shadow state")
assert(
    children_calls > before_forget_calls,
    "forget(bufnr) should force a new shadow collection"
)

vim.cmd("qa!")
