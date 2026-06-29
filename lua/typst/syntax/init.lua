local package_extensions = require("typst.syntax.package_extensions")
local package_highlights = require("typst.syntax.package_highlights")

local M = {}

M.package_extensions = package_extensions.list
M.package_matches = package_highlights.matches
M.refresh = package_highlights.refresh
M.clear = package_highlights.clear
M.apply = package_highlights.apply
M.namespace = package_highlights.namespace
M.package_key = package_extensions.package_key

return M
