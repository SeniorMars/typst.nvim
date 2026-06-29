local completion_lsp = require("typst.completion.lsp")
local completion_packages = require("typst.completion.packages")
local completion_context = require("typst.completion.context")
local completion_csl = require("typst.completion.csl")
local completion_raw = require("typst.completion.raw")
local completion_colors = require("typst.completion.colors")
local completion_fonts = require("typst.completion.fonts")
local completion_paths = require("typst.completion.paths")
local completion_parameters = require("typst.completion.parameters")
local completion_position = require("typst.completion.position")
local completion_project = require("typst.completion.project")
local completion_stdlib = require("typst.completion.stdlib")
local metadata = require("typst.metadata")
local telemetry = require("typst.core.telemetry")

local M = {}

---@class TypstCompletionSource
---@field is_available? fun(): boolean
---@field get_trigger_characters? fun(): string[]
---@field complete? fun(self: any, params: table, callback: fun(result: table))
---@field get_completions? fun(self: any, params: table, callback: fun(result: table))

local source_sequences = {
    cmp = 0,
    blink = 0,
}

local lsp_kind_by_vim_kind = {
    t = vim.lsp.protocol.CompletionItemKind.Text,
    m = vim.lsp.protocol.CompletionItemKind.Method,
    f = vim.lsp.protocol.CompletionItemKind.Function,
    v = vim.lsp.protocol.CompletionItemKind.Variable,
    k = vim.lsp.protocol.CompletionItemKind.Keyword,
    s = vim.lsp.protocol.CompletionItemKind.Snippet,
    r = vim.lsp.protocol.CompletionItemKind.Reference,
    d = vim.lsp.protocol.CompletionItemKind.Folder,
    o = vim.lsp.protocol.CompletionItemKind.Operator,
}

local function item_documentation(item)
    if type(item.info) ~= "string" or item.info == "" then
        return nil
    end

    return {
        kind = "markdown",
        value = item.info,
    }
end

local function semantic_lsp_item(item)
    local typst = item.user_data and item.user_data.typst
    return type(typst) == "table" and typst.lsp_item or nil
end

local function lsp_application_requirements(payload)
    local unsupported = {}
    if payload.text_edit ~= nil then
        unsupported.textEdit = true
    end
    if payload.insert_range ~= nil or payload.replace_range ~= nil then
        unsupported.insertReplaceEdit = true
    end
    if payload.snippet then
        unsupported.snippet = true
    end
    if payload.additional_edits ~= nil then
        unsupported.additionalTextEdits = true
    end
    if payload.command ~= nil then
        unsupported.command = true
    end

    return next(unsupported) and unsupported or nil
end

local function omnifunc_item(item)
    local payload = semantic_lsp_item(item)
    local unsupported = type(payload) == "table"
            and lsp_application_requirements(payload)
        or nil
    if not unsupported then
        return item
    end

    item = vim.deepcopy(item)
    item.user_data = item.user_data or {}
    item.user_data.typst = item.user_data.typst or {}
    item.user_data.typst.frontend = {
        name = "omnifunc",
        applies_lsp_edits = false,
        unsupported = unsupported,
        reason = "omnifunc can only return insertion text; use native, cmp, or blink for LSP completion edits",
    }
    return item
end

local function apply_lsp_edit_fields(out, item)
    local payload = semantic_lsp_item(item)
    if type(payload) ~= "table" then
        return out
    end

    out.label = payload.label or out.label
    out.insertText = payload.new_text or out.insertText
    out.filterText = payload.filter_text or out.filterText
    out.sortText = payload.sort_text or out.sortText
    if payload.text_edit ~= nil then
        out.textEdit = vim.deepcopy(payload.text_edit)
    end
    if payload.snippet then
        out.insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet
    elseif payload.raw and payload.raw.insertTextFormat then
        out.insertTextFormat = payload.raw.insertTextFormat
    end
    if payload.additional_edits ~= nil then
        out.additionalTextEdits = vim.deepcopy(payload.additional_edits)
    end
    if payload.command ~= nil then
        out.command = vim.deepcopy(payload.command)
    end
    return out
end

local function lsp_item(item)
    return apply_lsp_edit_fields({
        label = item.abbr or item.word,
        insertText = item.word,
        filterText = item.word,
        detail = item.menu,
        documentation = item_documentation(item),
        kind = lsp_kind_by_vim_kind[item.kind]
            or vim.lsp.protocol.CompletionItemKind.Value,
        data = item.user_data,
    }, item)
end

local function cmp_item(item)
    return apply_lsp_edit_fields({
        label = item.abbr or item.word,
        word = item.word,
        insertText = item.word,
        filterText = item.word,
        menu = item.menu,
        kind = lsp_kind_by_vim_kind[item.kind]
            or vim.lsp.protocol.CompletionItemKind.Value,
        documentation = item_documentation(item),
        data = item.user_data,
    }, item)
end

local function blink_item(item)
    return apply_lsp_edit_fields({
        label = item.abbr or item.word,
        insertText = item.word,
        filterText = item.word,
        kind = lsp_kind_by_vim_kind[item.kind]
            or vim.lsp.protocol.CompletionItemKind.Value,
        detail = item.menu,
        documentation = item.info,
        data = item.user_data,
    }, item)
end

local function line_start(opts)
    local line = opts.line
    if not line and opts.bufnr == vim.api.nvim_get_current_buf() then
        line = vim.api.nvim_get_current_line()
    end
    line = line or ""
    local col = opts.col
    if not col then
        if opts.pos then
            col = opts.pos[2]
        elseif opts.bufnr == vim.api.nvim_get_current_buf() then
            col = vim.api.nvim_win_get_cursor(0)[2]
        else
            col = #line
        end
    end
    return completion_context.start(line, col)
end

local function source_opts(params, defaults)
    defaults = defaults or {}
    params = params or {}
    local bufnr = params.bufnr
        or (params.context and params.context.bufnr)
        or defaults.bufnr
        or vim.api.nvim_get_current_buf()
    local resolved = completion_position.resolve({
        pos = params.pos or defaults.pos,
        line = params.line
            or params.context and params.context.cursor_before_line,
    }, bufnr)
    local line = params.line
        or params.context and params.context.cursor_before_line
        or resolved and resolved.line
        or (
            bufnr == vim.api.nvim_get_current_buf()
                and vim.api.nvim_get_current_line()
            or ""
        )
    local col = params.col
        or params.offset
        or (resolved and resolved.col)
        or #line
    local start_col = line_start({
        line = line,
        col = col,
        bufnr = bufnr,
    })
    local base = params.base or line:sub(start_col + 1, col)
    return vim.tbl_extend("force", defaults, {
        bufnr = bufnr,
        base = base,
        line = line,
        col = col,
        changedtick = vim.api.nvim_buf_is_valid(bufnr)
                and vim.api.nvim_buf_get_changedtick(bufnr)
            or nil,
    })
end

local function next_sequence(source)
    source_sequences[source] = (source_sequences[source] or 0) + 1
    return source_sequences[source]
end

local function request_current(source, sequence, request_opts)
    if source_sequences[source] ~= sequence then
        return false
    end

    local bufnr = request_opts.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    if
        request_opts.changedtick
        and vim.api.nvim_buf_get_changedtick(bufnr)
            ~= request_opts.changedtick
    then
        return false
    end

    return true
end

local function call_refresh_hook(opts, source)
    local hook = opts
        and (opts[source .. "_refresh"] or opts.refresh or opts.on_refresh)
    if type(hook) == "function" then
        local ok, refreshed = pcall(hook, source, opts)
        if ok then
            return refreshed ~= false
        end
    end
end

local function trigger_cmp_refresh(opts)
    if call_refresh_hook(opts, "cmp") then
        return true
    end

    local ok, cmp = pcall(require, "cmp")
    if ok and type(cmp) == "table" and type(cmp.complete) == "function" then
        local reason = cmp.ContextReason and cmp.ContextReason.TriggerOnly
            or nil
        local called = pcall(cmp.complete, reason and { reason = reason } or {})
        return called
    end

    return false
end

local function trigger_blink_refresh(opts)
    if call_refresh_hook(opts, "blink") then
        return true
    end

    local ok, blink = pcall(require, "blink.cmp")
    if not ok or type(blink) ~= "table" then
        return false
    end

    if type(blink.show) == "function" then
        return pcall(blink.show)
    end
    if type(blink.reload) == "function" then
        return pcall(blink.reload)
    end

    return false
end

local function complete_impl(opts)
    opts = opts or {}
    local base = opts.base or ""
    local context = opts.context
        or completion_context.kind(opts.bufnr, opts.pos, {
            parameter_value = completion_parameters.value_context,
            parameter = completion_parameters.context,
        })
    if not context then
        return {}
    end
    local limit = opts.limit or 80
    local catalog = metadata.catalog()
    local items = {}

    -- Source order is part of completion behavior: Tinymist may provide the
    -- most semantic edits, context-specific local sources win next, and broad
    -- project/package/stdlib fallbacks come last.
    local function add(item)
        items[#items + 1] = item
        return #items >= limit
    end

    for _, item in ipairs(completion_lsp.items(opts, base, context)) do
        if add(item) then
            return items
        end
    end

    if context == "csl_style" then
        for _, item in ipairs(completion_csl.items(opts, base, catalog)) do
            if add(item) then
                return items
            end
        end
        return items
    end

    if context == "raw_language" then
        for _, item in ipairs(completion_raw.items(opts, base)) do
            if add(item) then
                return items
            end
        end
        return items
    end

    if context == "path" or context == "file_path" then
        for _, item in ipairs(completion_paths.items(opts, base)) do
            if add(item) then
                return items
            end
        end
        return items
    end

    if context == "color" then
        for _, item in ipairs(completion_colors.items(opts, base, catalog)) do
            if add(item) then
                return items
            end
        end
        return items
    end

    if context == "font_family" or context == "font" then
        for _, item in ipairs(completion_fonts.items(opts, base)) do
            if add(item) then
                return items
            end
        end
        return items
    end

    if context == "parameter" or context == "named_parameter" then
        for _, item in ipairs(completion_parameters.items(opts, base)) do
            if add(item) then
                return items
            end
        end
        return items
    end

    if context == "parameter_value" then
        for _, item in ipairs(completion_parameters.value_items(opts, base)) do
            if add(item) then
                return items
            end
        end
        return items
    end

    if context ~= "math" or opts.include_project_in_math then
        for _, item in ipairs(completion_project.items(opts, base)) do
            if add(item) then
                return items
            end
        end
    end

    if context ~= "math" or opts.include_project_in_math then
        for _, item in ipairs(completion_packages.items(opts, base)) do
            if add(item) then
                return items
            end
        end
    end

    for _, item in
        ipairs(completion_stdlib.items(base, context, catalog, limit - #items))
    do
        if add(item) then
            return items
        end
    end

    return items
end

--- Return typst.nvim completion items for the current buffer context.
---@param opts? table Completion options such as buffer, base, context, and limit.
---@return table[] items Completion items in typst.nvim's internal item shape.
function M.complete(opts)
    return telemetry.time("completion.complete", function()
        return complete_impl(opts)
    end)
end

--- Neovim omnifunc adapter for typst.nvim completions.
---@param findstart integer Nonzero when Neovim asks for the completion start column.
---@param base? string Completion base supplied by omnifunc.
---@return integer|table result Start column or completion item list.
function M.omnifunc(findstart, base)
    if findstart == 1 then
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(0)[2]
        return completion_context.start(line, col)
    end

    local items = {}
    for _, item in
        ipairs(M.complete({
            bufnr = vim.api.nvim_get_current_buf(),
            base = base or "",
        }))
    do
        items[#items + 1] = omnifunc_item(item)
    end
    return items
end

--- Return LSP-style completion items for native Neovim completion.
---@param opts? table Completion options forwarded to `complete`.
---@return table result LSP CompletionList-like result.
function M.native(opts)
    local items = {}
    for _, item in ipairs(M.complete(opts)) do
        items[#items + 1] = lsp_item(item)
    end

    return {
        isIncomplete = false,
        items = items,
    }
end

--- Return nvim-cmp completion items.
---@param opts? table Completion options forwarded to `complete`.
---@return table[] items nvim-cmp item list.
function M.cmp(opts)
    local items = {}
    for _, item in ipairs(M.complete(opts)) do
        items[#items + 1] = cmp_item(item)
    end
    return items
end

--- Return blink.cmp completion items.
---@param opts? table Completion options forwarded to `complete`.
---@return table[] items blink.cmp item list.
function M.blink(opts)
    local items = {}
    for _, item in ipairs(M.complete(opts)) do
        items[#items + 1] = blink_item(item)
    end
    return items
end

--- Build an nvim-cmp source adapter for typst.nvim completions.
---@param opts? table Source options merged into each completion request.
---@return table source nvim-cmp source object.
function M.cmp_source(opts)
    opts = opts or {}
    return {
        is_available = function()
            return vim.bo.filetype == "typst"
        end,
        get_trigger_characters = function()
            return { "#", "@", ".", ":", '"' }
        end,
        complete = function(_, params, callback)
            local request_opts = source_opts(params, opts)
            local sequence = next_sequence("cmp")
            request_opts.completion_session = ("cmp:%d"):format(sequence)
            local refreshed = false
            request_opts.on_tinymist_results = function()
                -- The first pass returns immediately from local/cache sources.
                -- A later Tinymist response may request one frontend refresh,
                -- but only while the buffer request is still current.
                if
                    refreshed
                    or not request_current("cmp", sequence, request_opts)
                then
                    return
                end
                refreshed = trigger_cmp_refresh(request_opts)
            end
            callback({
                isIncomplete = false,
                items = M.cmp(request_opts),
            })
        end,
    }
end

--- Build a blink.cmp source adapter for typst.nvim completions.
---@param opts? table Source options merged into each completion request.
---@return table source blink.cmp source object.
function M.blink_source(opts)
    opts = opts or {}
    return {
        name = "typst.nvim",
        enabled = function()
            return vim.bo.filetype == "typst"
        end,
        get_trigger_characters = function()
            return { "#", "@", ".", ":", '"' }
        end,
        get_completions = function(_, params, callback)
            local request_opts = source_opts(params, opts)
            local sequence = next_sequence("blink")
            request_opts.completion_session = ("blink:%d"):format(sequence)
            local refreshed = false
            request_opts.on_tinymist_results = function()
                if
                    refreshed
                    or not request_current("blink", sequence, request_opts)
                then
                    return
                end
                refreshed = trigger_blink_refresh(request_opts)
            end
            callback({
                is_incomplete_forward = false,
                is_incomplete_backward = false,
                items = M.blink(request_opts),
            })
        end,
    }
end

--- Clear completion caches owned by typst.nvim.
function M.reset()
    completion_csl.reset()
    completion_fonts.reset()
    completion_lsp.reset()
    completion_raw.reset()
end

--- Return signature help metadata through the completion subsystem.
---@param opts? table Signature options, including buffer and position.
---@return table? signature Signature help payload, or nil outside a call.
function M.signature(opts)
    return completion_parameters.signature(opts)
end

return M
