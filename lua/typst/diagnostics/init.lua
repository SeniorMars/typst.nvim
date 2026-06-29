local config = require("typst.config")
local diagnostic_parser = require("typst.diagnostics.parser")
local events = require("typst.core.events")
local diagnostics_service = require("typst.project.services.diagnostics")
local quickfix = require("typst.diagnostics.quickfix")
local semantic_provider = require("typst.integrations.semantic_provider")

local M = {}

M.namespace = vim.api.nvim_create_namespace("typst.nvim")
local default_source = "compiler"
local global_namespaces = {
    [default_source] = M.namespace,
}

local function source_key(source)
    if type(source) ~= "string" or source == "" then
        return default_source
    end

    local lowered = source:lower()
    if lowered:find("grammar", 1, true) then
        return "grammar"
    end
    if lowered:find("lint", 1, true) then
        return "lint"
    end
    if lowered:find("bibliography", 1, true) then
        return "bibliography"
    end
    if lowered:find("font", 1, true) then
        return "fonts"
    end

    local key = lowered:gsub("[^%w_%-]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    return key ~= "" and key or default_source
end

local function ensure_project_namespaces(project)
    project.diagnostics_namespaces = project.diagnostics_namespaces or {}
    if
        project.diagnostics_namespace
        and not project.diagnostics_namespaces[default_source]
    then
        project.diagnostics_namespaces[default_source] =
            project.diagnostics_namespace
    end
    return project.diagnostics_namespaces
end

--- Return the diagnostic namespace for a project/source pair.
---@param project? table Project state, or nil for a global source namespace.
---@param source? string Diagnostic source such as compiler, lint, or grammar.
---@return integer namespace Neovim diagnostic namespace id.
function M.namespace_for(project, source)
    local key = source_key(source)
    if not project then
        if not global_namespaces[key] then
            global_namespaces[key] =
                vim.api.nvim_create_namespace("typst.nvim:" .. key)
        end
        return global_namespaces[key]
    end

    -- Keep compiler, lint, grammar, bibliography, and font diagnostics in
    -- separate namespaces so clearing one source does not erase another source
    -- that may have refreshed independently.
    local namespaces = ensure_project_namespaces(project)
    if not namespaces[key] then
        namespaces[key] = vim.api.nvim_create_namespace(
            ("typst.nvim:%s:%s"):format(
                tostring(project.key or project.main),
                key
            )
        )
    end

    if key == default_source then
        project.diagnostics_namespace = namespaces[key]
    end

    return namespaces[key]
end

--- Check whether compiler fallback diagnostics should publish for a project.
---@param project table Project state used to detect Tinymist ownership.
---@return boolean publish True when typst.nvim should publish parsed compiler diagnostics.
function M.should_publish(project)
    local diagnostics_config = config.unsafe_get().diagnostics
    if not diagnostics_config.enabled or diagnostics_config.source == "off" then
        return false
    end

    if diagnostics_config.source == "always" then
        return true
    end

    -- In fallback mode, compiler diagnostics publish unless the active
    -- semantic provider explicitly owns diagnostics. Tinymist keeps its
    -- existing native-LSP/coc-tinymist ownership behavior; custom providers
    -- must opt in so symbol-only providers do not hide compiler output.
    return not semantic_provider.owns_diagnostics(project)
end

--- Return the active compiler-diagnostic policy state for a project.
---@param project table Project state used to detect Tinymist ownership.
---@return string state Policy key used by status/reporting code.
function M.policy_state(project)
    local diagnostics_config = config.unsafe_get().diagnostics
    if not diagnostics_config.enabled or diagnostics_config.source == "off" then
        return "off"
    end

    if diagnostics_config.source == "always" then
        return "always"
    end

    if M.should_publish(project) then
        return "fallback_active"
    end

    if semantic_provider.name() ~= "tinymist" then
        return "fallback_suppressed_by_semantic_provider"
    end

    return "fallback_suppressed_by_tinymist"
end

--- Return a human-readable compiler-diagnostic policy label.
---@param project table Project state used to detect Tinymist ownership.
---@return string label Policy label for status/reporting code.
function M.policy_label(project)
    return ({
        off = "off",
        always = "always",
        fallback_active = "fallback active",
        fallback_suppressed_by_tinymist = "fallback suppressed by Tinymist/Coc",
        fallback_suppressed_by_semantic_provider = "fallback suppressed by semantic provider",
    })[M.policy_state(project)]
end

local function diagnostic_total(by_buffer)
    local count = 0
    for _, diagnostics in pairs(by_buffer or {}) do
        count = count + #diagnostics
    end
    return count
end

--- Replace the Typst-owned quickfix list with diagnostics.
---@param project table Project state that owns the quickfix list.
---@param by_buffer table<integer, table[]> Diagnostics grouped by buffer.
---@return table[] items Quickfix items that were set.
function M.set_quickfix(project, by_buffer)
    return quickfix.set(project, by_buffer)
end

--- Convert diagnostics grouped by buffer into sorted quickfix items.
---@param by_buffer table<integer, table[]> Diagnostics grouped by buffer.
---@param opts? table Quickfix item conversion options.
---@return table[] items Sorted quickfix items.
function M.quickfix_items(by_buffer, opts)
    return quickfix.items(by_buffer, opts)
end

--- Open the current diagnostics for a project in quickfix.
---@param project table Project state whose diagnostics are opened.
---@param opts? table Quickfix options, including optional diagnostic source.
---@return table[] items Quickfix items that were set/opened.
function M.quickfix(project, opts)
    opts = opts or {}
    return quickfix.open(project, M.namespace_for(project, opts.source), opts)
end

local function source_buffers(project, key)
    local diagnostic_state = diagnostics_service.get(project) or {}
    diagnostic_state.by_source = diagnostic_state.by_source or {}
    diagnostic_state.by_source[key] = diagnostic_state.by_source[key] or {}
    return diagnostic_state.by_source[key]
end

local function source_keys(project, source)
    if source then
        return { source_key(source) }
    end

    local keys = {}
    local seen = {}
    for key in pairs(project.diagnostics_namespaces or {}) do
        keys[#keys + 1] = key
        seen[key] = true
    end
    local diagnostic_state = diagnostics_service.get(project) or {}
    for key in pairs(diagnostic_state.by_source or {}) do
        if not seen[key] then
            keys[#keys + 1] = key
            seen[key] = true
        end
    end
    if #keys == 0 then
        keys[1] = default_source
    end
    return keys
end

local function rebuild_diagnostic_buffers(project)
    local diagnostic_buffers = {}
    local diagnostic_state = diagnostics_service.get(project) or {}
    for _, buffers in pairs(diagnostic_state.by_source or {}) do
        for bufnr in pairs(buffers) do
            diagnostic_buffers[bufnr] = true
        end
    end
    diagnostics_service.set(project, { buffers = diagnostic_buffers })
end

--- Clear all project-owned diagnostics from one buffer.
---@param project table Project state whose diagnostic namespaces own the buffer.
---@param bufnr integer Buffer whose diagnostics should be reset.
---@param opts? table Clear options; `source` restricts which namespace is reset.
---@return boolean cleared True when any tracked diagnostics or quickfix ownership existed.
function M.clear_buffer(project, bufnr, opts)
    opts = opts or {}
    if type(project) ~= "table" or type(bufnr) ~= "number" then
        return false
    end

    local keys = source_keys(project, opts.source)
    local had_diagnostics = false
    local owned_list = quickfix.owns(project)

    for _, key in ipairs(keys) do
        local buffers = source_buffers(project, key)
        if buffers[bufnr] then
            had_diagnostics = true
        end
        local namespace = M.namespace_for(project, key)
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.diagnostic.reset(namespace, bufnr)
        end
        buffers[bufnr] = nil
    end

    rebuild_diagnostic_buffers(project)

    local diagnostic_state = diagnostics_service.get(project) or {}
    local remaining = next(diagnostic_state.buffers or {}) ~= nil
    if owned_list and not remaining then
        quickfix.clear(project)
    end

    if opts.emit ~= false and (had_diagnostics or owned_list) then
        events.emit("TypstDiagnosticsCleared", project, {
            diagnostics_count = 0,
            diagnostic_buffers = vim.tbl_count(diagnostic_state.buffers or {}),
            bufnr = bufnr,
        })
    end

    return had_diagnostics or owned_list
end

--- Clear diagnostics for one source or all project-owned sources.
---@param project table Project state whose diagnostics should be cleared.
---@param opts? table Clear options; `source` restricts which namespace is reset.
function M.clear(project, opts)
    opts = opts or {}
    local keys = source_keys(project, opts.source)
    local had_diagnostics = false
    local owned_list = quickfix.owns(project)

    for _, key in ipairs(keys) do
        local buffers = source_buffers(project, key)
        had_diagnostics = had_diagnostics or next(buffers) ~= nil
        local namespace = M.namespace_for(project, key)
        for bufnr in pairs(buffers) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.diagnostic.reset(namespace, bufnr)
            end
        end
        local diagnostic_state = diagnostics_service.get(project) or {}
        diagnostic_state.by_source = diagnostic_state.by_source or {}
        diagnostic_state.by_source[key] = {}
    end

    rebuild_diagnostic_buffers(project)

    if owned_list then
        quickfix.clear(project)
    end

    if opts.emit ~= false and (had_diagnostics or owned_list) then
        events.emit("TypstDiagnosticsCleared", project, {
            diagnostics_count = 0,
            diagnostic_buffers = 0,
        })
    end
end

--- Parse and publish Typst diagnostics from tool output.
---@param project table Project state whose buffers receive diagnostics.
---@param text string Raw compiler/lint/grammar output.
---@param opts? table Publish options, including optional diagnostic source.
---@return table<integer, table[]> by_buffer Diagnostics grouped by buffer.
function M.publish(project, text, opts)
    opts = opts or {}
    local key = source_key(opts.source)
    M.clear(project, { emit = false, source = key })

    local by_buffer = M.parse(project, text, opts)
    local namespace = M.namespace_for(project, key)
    local buffers = source_buffers(project, key)

    for bufnr, diagnostics in pairs(by_buffer) do
        vim.diagnostic.set(namespace, bufnr, diagnostics)
        buffers[bufnr] = true
    end
    rebuild_diagnostic_buffers(project)

    quickfix.maybe_set(project, by_buffer)

    events.emit("TypstDiagnosticsPublished", project, {
        diagnostics_count = diagnostic_total(by_buffer),
        diagnostic_buffers = vim.tbl_count(by_buffer),
    })

    return by_buffer
end

--- Publish native Neovim diagnostics grouped by buffer.
---@param project table Project state whose buffers receive diagnostics.
---@param by_buffer table<integer, table[]> Diagnostics grouped by buffer.
---@param opts? table Publish options, including optional diagnostic source.
---@return table<integer, table[]> by_buffer Diagnostics that were published.
---@return table[] quickfix_items Quickfix items that were set when enabled.
function M.publish_by_buffer(project, by_buffer, opts)
    opts = opts or {}
    local key = source_key(opts.source)
    M.clear(project, { emit = false, source = key })

    local namespace = M.namespace_for(project, key)
    local buffers = source_buffers(project, key)
    local published = {}

    for bufnr, buffer_diagnostics in pairs(by_buffer or {}) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            local diagnostics_for_buffer =
                vim.deepcopy(buffer_diagnostics or {})
            vim.diagnostic.set(namespace, bufnr, diagnostics_for_buffer)
            if #diagnostics_for_buffer > 0 then
                buffers[bufnr] = true
                published[bufnr] = diagnostics_for_buffer
            end
        end
    end
    rebuild_diagnostic_buffers(project)

    local items = quickfix.maybe_set(project, published)
    events.emit("TypstDiagnosticsPublished", project, {
        diagnostics_count = diagnostic_total(published),
        diagnostic_buffers = vim.tbl_count(published),
    })

    return published, items
end

--- Parse Typst diagnostics without publishing them to Neovim.
---@param project table Project state used for path resolution.
---@param text string Raw compiler/lint/grammar output.
---@param opts? table Parser options.
---@return table<integer, table[]> by_buffer Diagnostics grouped by buffer.
function M.parse(project, text, opts)
    return diagnostic_parser.parse(project, text, opts)
end

--- Reset global diagnostic UI state.
function M.reset()
    quickfix.reset()
end

return M
