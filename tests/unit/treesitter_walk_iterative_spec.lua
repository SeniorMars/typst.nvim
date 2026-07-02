local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local treesitter = require("typst.core.treesitter")

local depth = 5000
local nodes = {}
for index = 1, depth do
    nodes[index] = {}
end

for index = 1, depth do
    nodes[index].child_node = nodes[index + 1]
    nodes[index].child_count = function(self)
        return self.child_node and 1 or 0
    end
    nodes[index].child = function(self, child_index)
        if child_index == 0 then
            return self.child_node
        end
        return nil
    end
end

local visited = 0
treesitter.walk(nodes[1], function(node)
    visited = visited + 1
    assert(node == nodes[visited], "walk should preserve preorder traversal")
end)

assert(visited == depth, "iterative Tree-sitter walk should visit deep trees")
