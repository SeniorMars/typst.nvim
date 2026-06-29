local M = require("typst.bibliography.parser")
local diagnostics = require("typst.bibliography.diagnostics")
local edit = require("typst.bibliography.edit")
local workflow = require("typst.bibliography.workflow")

M.diagnostics = diagnostics.check
M.clear_diagnostics = diagnostics.clear
M.diagnostics_namespace = diagnostics.namespace
M.diagnostics_namespace_for = diagnostics.namespace_for
M.foldexpr = edit.foldexpr
M.indentexpr = edit.indentexpr
M.expanded_fields = workflow.expanded_fields
M.search = workflow.search
M.insert_text = workflow.insert_text
M.insert = workflow.insert
M.open = workflow.open
M.preview = workflow.preview
M.attachment = workflow.attachment
M.attachments = workflow.attachments
M.rename_plan = workflow.rename_plan
M.rename_key = workflow.rename_key
M.status = workflow.status

return M
