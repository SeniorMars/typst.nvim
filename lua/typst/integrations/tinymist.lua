local clients = require("typst.integrations.tinymist.clients")
local code_actions = require("typst.integrations.tinymist.code_actions")
local commands = require("typst.integrations.tinymist.commands")
local features = require("typst.integrations.tinymist.features")
local requests = require("typst.integrations.tinymist.requests")
local symbols = require("typst.integrations.tinymist.symbols")

---@class typst.Tinymist
---@field clients fun(...): table
---@field available fun(bufnr: integer|nil): boolean
---@field available_for_project fun(project: table): boolean
---@field lsp_backend fun(): string
---@field lsp_enabled fun(): boolean
---@field lsp_mode fun(): string
---@field coc_active fun(): boolean
---@field start_command fun(): string[]
---@field startability fun(): table
---@field ensure fun(bufnr: integer|nil, project: table|nil): boolean, string
---@field request fun(bufnr: integer|nil, method: string, opts: table|nil, callback: function|nil): table|nil
---@field supports fun(bufnr: integer|nil, method: string): boolean
---@field execute_command fun(command:string|table, arguments:table|nil, opts:table|nil): table
---@field code_actions fun(bufnr: integer|nil, opts: table): table|nil
---@field find_code_action fun(bufnr: integer|nil, action_name: string, opts: table): table|nil
---@field apply_code_action fun(candidate: table, opts: table|nil): table
---@field apply_code_action_async fun(candidate: table, opts: table|nil, callback:function): table|nil
---@field structural_action fun(action_name: string, opts: table): table|nil
---@field document_highlight fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field document_links fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field document_symbols fun(bufnr: integer, timeout_or_opts: table|nil): table|nil
---@field folding_ranges fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field signature_help fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field document_color fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field color_presentation fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field code_lens fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field workspace_symbols fun(project: table, opts: table|nil): table|nil
---@field selection_range fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field on_enter fun(bufnr: integer|nil, opts: table|nil): table|nil
---@field hover fun(bufnr: integer|nil, opts: table): table|nil
---@field definition fun(bufnr: integer|nil, opts: table): table|nil
---@field references fun(bufnr: integer|nil, opts: table): table|nil
---@field rename fun(bufnr: integer|nil, new_name: string, opts: table): table|nil
---@field format fun(bufnr: integer|nil, opts: table|nil, callback: function|nil): table|nil
local M = {}

M.clients = clients.clients
M.available = clients.available
M.available_for_project = clients.available_for_project
M.lsp_backend = clients.lsp_backend
M.lsp_enabled = clients.lsp_enabled
M.lsp_mode = clients.lsp_mode
M.coc_active = clients.coc_active
M.start_command = clients.start_command
M.startability = clients.startability
M.ensure = clients.ensure

M.request = features.request
M.supports = features.supports
M.execute_command = commands.execute_command
M.document_highlight = features.document_highlight
M.document_links = features.document_links
M.folding_ranges = features.folding_ranges
M.signature_help = features.signature_help
M.document_color = features.document_color
M.color_presentation = features.color_presentation
M.code_lens = features.code_lens
M.selection_range = features.selection_range
M.on_enter = features.on_enter

M.code_actions = code_actions.code_actions
M.find_code_action = code_actions.find_code_action
M.apply_code_action = code_actions.apply_code_action
M.apply_code_action_async = code_actions.apply_code_action_async
M.structural_action = code_actions.structural_action

M.document_symbols = symbols.document_symbols
M.workspace_symbols = symbols.workspace_symbols

M.hover = requests.hover
M.definition = requests.definition
M.references = requests.references
M.rename = requests.rename
M.format = requests.format

return M
