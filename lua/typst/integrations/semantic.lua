local providers = require("typst.integrations.providers")
local provider_adapter = require("typst.integrations.provider_adapter")
local semantic_provider = require("typst.integrations.semantic_provider")
local position = require("typst.integrations.tinymist.position")
local reports = require("typst.ui.reports")
local tinymist = require("typst.integrations.tinymist")
local util = require("typst.core.util")

local M = {}
local namespace = vim.api.nvim_create_namespace("typst.semantic")
local semantic_result_fields = {
    actions = true,
    code_actions = true,
    colors = true,
    count = true,
    definitions = true,
    edits = true,
    hints = true,
    items = true,
    lenses = true,
    links = true,
    presentations = true,
    range = true,
    references = true,
    symbols = true,
}

-- Semantic features are callback-first because Tinymist answers over LSP.
-- Synchronous callers can still use non-Tinymist providers, but Tinymist paths
-- return async_required unless the caller gives a callback.

local function async_required(method)
    return {
        ok = false,
        reason = "async_required",
        provider = "tinymist",
        method = method,
        message = "Tinymist semantic requests require a callback",
    }
end

local notify_user = require("typst.core.notify").user

local function provider_run(name, project, opts)
    -- Custom semantic providers override Tinymist on a per-feature basis. They
    -- receive a snapshot context so provider code cannot mutate project state.
    local provider = semantic_provider.resolve(opts.provider)
    if provider == nil or provider == "tinymist" then
        return nil
    end
    local provider_project = providers.project_context(project)
    if type(provider) == "function" then
        return provider_adapter.invoke(provider, nil, provider_project, opts, {
            kind = "semantic",
            provider_name = "callback",
            args = { name, provider_project, opts },
            async = false,
            result_fields = semantic_result_fields,
            invalid_result_message = "Semantic provider returned no result",
        })
    end
    if type(provider[name]) == "function" then
        return provider_adapter.invoke(provider, name, provider_project, opts, {
            kind = "semantic",
            provider_name = semantic_provider.provider_name(provider),
            args = { provider_project, opts },
            async = false,
            result_fields = semantic_result_fields,
            invalid_result_message = "Semantic provider returned no result",
        })
    end
    if type(provider.run) == "function" then
        return provider_adapter.invoke(
            provider,
            "run",
            provider_project,
            opts,
            {
                kind = "semantic",
                provider_name = semantic_provider.provider_name(provider),
                args = { name, provider_project, opts },
                async = false,
                result_fields = semantic_result_fields,
                invalid_result_message = "Semantic provider returned no result",
            }
        )
    end
end

local function open_lines(title, filetype, lines, opts)
    if opts.open == false then
        return nil
    end
    return reports.open_scratch_buffer(title, filetype, lines)
end

local function clamp_channel(value)
    value = tonumber(value) or 0
    value = math.max(0, math.min(1, value))
    return math.floor(value * 255 + 0.5)
end

local function color_hex(color)
    local red = clamp_channel(color.red)
    local green = clamp_channel(color.green)
    local blue = clamp_channel(color.blue)
    local alpha = color.alpha ~= nil and clamp_channel(color.alpha) or nil
    if alpha and alpha < 255 then
        return ("#%02x%02x%02x%02x"):format(red, green, blue, alpha)
    end
    return ("#%02x%02x%02x"):format(red, green, blue)
end

local function swatch_group(color)
    local hex = color_hex(color)
    local group = "TypstSemanticColor" .. hex:gsub("[^%x]", "")
    pcall(vim.api.nvim_set_hl, 0, group, {
        fg = hex:sub(1, 7),
        bg = hex:sub(1, 7),
    })
    return group, hex
end

local function decorate_source_colors(bufnr, colors, encoding)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    for _, item in ipairs(colors or {}) do
        local color = item.color or {}
        local range = item.range or {}
        local start = range.start or {}
        local row = start.line or 0
        local col = position.buffer_lsp_character_to_byte_col(
            bufnr,
            row,
            start.character or 0,
            encoding or "utf-16"
        )
        local group = swatch_group(color)
        vim.api.nvim_buf_set_extmark(bufnr, namespace, row, col, {
            virt_text = { { " ■", group } },
            virt_text_pos = "eol",
            hl_mode = "combine",
        })
    end
end

local function decorate_report_colors(bufnr, swatches)
    if not bufnr then
        return
    end
    for _, swatch in ipairs(swatches or {}) do
        if vim.hl and vim.hl.range then
            pcall(
                vim.hl.range,
                bufnr,
                namespace,
                swatch.group,
                { swatch.row, 0 },
                { swatch.row, 1 }
            )
        else
            local add_highlight = vim.api["nvim_buf_add_" .. "highlight"]
            pcall(
                add_highlight,
                bufnr,
                namespace,
                swatch.group,
                swatch.row,
                0,
                1
            )
        end
    end
end

local function text_edit_like(value)
    return type(value) == "table"
        and type(value.range) == "table"
        and type(value.newText) == "string"
end

local function apply_lsp_edit(bufnr, edit, encoding)
    encoding = encoding or "utf-16"
    if type(edit) ~= "table" then
        return false, "empty_edit"
    end

    if edit.changes or edit.documentChanges then
        vim.lsp.util.apply_workspace_edit(edit, encoding)
        return true
    end

    if text_edit_like(edit) then
        vim.lsp.util.apply_text_edits({ edit }, bufnr, encoding)
        return true
    end

    if text_edit_like(edit[1]) then
        vim.lsp.util.apply_text_edits(edit, bufnr, encoding)
        return true
    end

    return false, "unsupported_edit"
end

local function cursor_lsp_position(bufnr, encoding)
    return position.current_position(bufnr, {
        offset_encoding = encoding or "utf-16",
        name = "tinymist",
    }) or {
        line = 0,
        character = 0,
    }
end

local function range_contains_position(range, position)
    if type(range) ~= "table" or type(position) ~= "table" then
        return false
    end

    local start = range.start or {}
    local finish = range["end"] or {}
    local line = position.line or 0
    local character = position.character or 0
    if line < (start.line or 0) or line > (finish.line or 0) then
        return false
    end
    if line == (start.line or 0) and character < (start.character or 0) then
        return false
    end
    if line == (finish.line or 0) and character >= (finish.character or 0) then
        return false
    end
    return true
end

local function report_action_lines(actions)
    local lines = { "typst.nvim code actions" }
    for index, candidate in ipairs(actions or {}) do
        local action = candidate.action or candidate
        lines[#lines + 1] = ("%d. %s"):format(
            index,
            action.title or action.command or "<code action>"
        )
        if type(action.kind) == "string" then
            lines[#lines + 1] = ("   kind: %s"):format(action.kind)
        end
        local command = action.command
        if type(command) == "table" then
            command = command.command
        elseif type(command) ~= "string" then
            command = nil
        end
        if command then
            lines[#lines + 1] = ("   command: %s"):format(command)
        end
    end
    if #(actions or {}) == 0 then
        lines[#lines + 1] = "No Tinymist code actions returned"
    end
    return lines
end

local function report_presentation_lines(presentations)
    local lines = { "typst.nvim color presentations" }
    for index, presentation in ipairs(presentations or {}) do
        local edit = presentation.textEdit or {}
        lines[#lines + 1] = ("%d. %s"):format(
            index,
            presentation.label or edit.newText or "<presentation>"
        )
    end
    if #(presentations or {}) == 0 then
        lines[#lines + 1] = "No Tinymist color presentations returned"
    end
    return lines
end

local function matching_presentation(presentations, selected)
    local index = tonumber(selected)
    if index then
        return presentations[index], index
    end

    local needle = tostring(selected or ""):lower()
    if needle == "" then
        return nil
    end
    for item_index, presentation in ipairs(presentations or {}) do
        local edit = presentation.textEdit or {}
        local label = presentation.label or edit.newText
        if type(label) == "string" and label:lower():find(needle, 1, true) then
            return presentation, item_index
        end
    end
end

--- Toggle Neovim LSP inlay hints for a Typst buffer.
---@param _? table Project argument kept for API symmetry.
---@param opts? table Toggle options, including buffer and explicit enabled state.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table result Toggle result or unsupported failure payload.
function M.inlay_hints_toggle(_, opts, notify)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if not vim.lsp.inlay_hint then
        return {
            ok = false,
            reason = "unsupported",
            message = "Neovim inlay hints are unavailable",
        }
    end

    local enabled = false
    if type(vim.lsp.inlay_hint.is_enabled) == "function" then
        enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = bufnr })
    end
    local next_enabled = opts.enabled
    if next_enabled == nil then
        next_enabled = not enabled
    end

    vim.lsp.inlay_hint.enable(next_enabled, { bufnr = bufnr })
    notify_user(
        notify,
        ("Typst inlay hints %s"):format(
            next_enabled and "enabled" or "disabled"
        )
    )
    return {
        ok = true,
        bufnr = bufnr,
        enabled = next_enabled,
    }
end

--- Request Tinymist code actions and optionally apply one by index.
---@param _ table Project argument kept for API symmetry.
---@param opts? table Code-action options; `callback` enables Tinymist requests.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|nil result Pending request or failure payload.
function M.code_action(_, opts, notify)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if type(opts.callback) ~= "function" then
        return async_required("textDocument/codeAction")
    end

    return tinymist.code_actions(
        bufnr,
        vim.tbl_extend("force", opts, {
            callback = function(result)
                if not result.ok then
                    opts.callback(result)
                    return
                end

                local actions = result.actions or {}
                local selected = opts.index or opts.execute or opts.action_index
                local index = tonumber(selected)
                if index and actions[index] then
                    tinymist.apply_code_action_async(actions[index], {
                        bufnr = bufnr,
                    }, function(apply_result)
                        result.applied = apply_result.ok == true
                        result.action = apply_result.action
                        result.apply_result = apply_result
                        if apply_result.ok then
                            notify_user(
                                notify,
                                ("Applied Typst code action: %s"):format(
                                    (apply_result.action or {}).title
                                        or "<code action>"
                                )
                            )
                        else
                            result.ok = false
                            result.reason = apply_result.reason
                            result.message = apply_result.message
                        end
                        result.count = #actions
                        opts.callback(result)
                    end)
                    return
                elseif selected ~= nil and not index then
                    local needle = tostring(selected):lower()
                    local candidate = nil
                    for _, item in ipairs(actions) do
                        local action = item.action or item
                        if
                            type(action.title) == "string"
                            and action.title:lower():find(needle, 1, true)
                        then
                            candidate = item
                            break
                        end
                    end
                    if candidate then
                        tinymist.apply_code_action_async(candidate, {
                            bufnr = bufnr,
                        }, function(apply_result)
                            result.applied = apply_result.ok == true
                            result.action = apply_result.action
                            result.apply_result = apply_result
                            if not apply_result.ok then
                                result.ok = false
                                result.reason = apply_result.reason
                                result.message = apply_result.message
                            end
                            result.count = #actions
                            opts.callback(result)
                        end)
                        return
                    end
                    result.ok = false
                    result.reason = "missing_action"
                    result.message = ("No Tinymist code action matching %s"):format(
                        tostring(selected)
                    )
                elseif selected ~= nil then
                    result.ok = false
                    result.reason = "missing_action"
                    result.message = ("No Tinymist code action at index %s"):format(
                        tostring(selected)
                    )
                elseif opts.open ~= false then
                    result.buffer = open_lines(
                        "typst.nvim code actions",
                        "typstsemantic",
                        report_action_lines(actions),
                        opts
                    )
                end

                result.count = #actions
                opts.callback(result)
            end,
        })
    )
end

--- Request Typst document color information and render a report buffer.
---@param project table Project state used for provider fallback context.
---@param opts? table Color-info options; `callback` enables Tinymist requests.
---@return table|nil result Provider result, pending request, or failure payload.
function M.color_info(project, opts)
    opts = opts or {}
    local provider_result = provider_run("color_info", project, opts)
    if provider_result ~= nil then
        return provider_result
    end

    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local function build_result(colors, encoding)
        colors = colors or {}
        encoding = encoding or opts.encoding or "utf-16"
        local lines = { "typst.nvim color information" }
        local swatches = {}
        for _, item in ipairs(colors) do
            local color = item.color or {}
            local range = item.range or {}
            local start = range.start or {}
            local group, hex = swatch_group(color)
            lines[#lines + 1] = ("■ %s  %d:%d rgba(%s, %s, %s, %s)"):format(
                hex,
                (start.line or 0) + 1,
                (start.character or 0) + 1,
                vim.inspect(color.red),
                vim.inspect(color.green),
                vim.inspect(color.blue),
                vim.inspect(color.alpha)
            )
            swatches[#swatches + 1] = { row = #lines - 1, group = group }
        end

        if opts.decorate ~= false then
            decorate_source_colors(bufnr, colors, encoding)
        end
        local report_buf =
            open_lines("typst.nvim colors", "typstsemantic", lines, opts)
        decorate_report_colors(report_buf, swatches)
        return {
            ok = true,
            colors = colors,
            count = #colors,
            buffer = report_buf,
        }
    end

    if type(opts.callback) == "function" then
        return tinymist.document_color(
            bufnr,
            vim.tbl_extend("force", opts, {
                guard_cursor = false,
                callback = function(result)
                    if not result.ok then
                        opts.callback(result)
                        return
                    end
                    opts.callback(
                        build_result(result.colors or {}, result.encoding)
                    )
                end,
            })
        )
    end

    return async_required("textDocument/documentColor")
end

--- Request color presentations for the color under the cursor.
---@param _ table Project argument kept for API symmetry.
---@param opts? table Presentation options; pass `index`/`execute` to apply one.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|nil result Pending request or failure payload.
function M.color_presentation(_, opts, notify)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if type(opts.callback) ~= "function" then
        return async_required("textDocument/colorPresentation")
    end

    return tinymist.document_color(
        bufnr,
        vim.tbl_extend("force", opts, {
            guard_cursor = opts.guard_cursor,
            callback = function(color_result)
                if not color_result.ok then
                    opts.callback(color_result)
                    return
                end

                local position = opts.position
                    or cursor_lsp_position(
                        bufnr,
                        color_result.encoding or "utf-16"
                    )
                local selected_color = opts.color
                local selected_range = opts.range
                if not selected_color or not selected_range then
                    for _, item in ipairs(color_result.colors or {}) do
                        if range_contains_position(item.range, position) then
                            selected_color = item.color
                            selected_range = item.range
                            break
                        end
                    end
                end

                if not selected_color or not selected_range then
                    opts.callback({
                        ok = false,
                        reason = "no_color",
                        provider = "tinymist",
                        method = "textDocument/colorPresentation",
                        message = "No Tinymist color literal under cursor",
                    })
                    return
                end

                tinymist.color_presentation(
                    bufnr,
                    vim.tbl_extend("force", opts, {
                        color = selected_color,
                        range = selected_range,
                        callback = function(presentation_result)
                            if not presentation_result.ok then
                                opts.callback(presentation_result)
                                return
                            end

                            local presentations = presentation_result.presentations
                                or {}
                            local selected = opts.index
                                or opts.execute
                                or opts.presentation_index
                            local presentation = selected ~= nil
                                    and matching_presentation(
                                        presentations,
                                        selected
                                    )
                                or nil
                            if presentation then
                                local applied = false
                                local reason = nil
                                if presentation.textEdit then
                                    local edits = { presentation.textEdit }
                                    for _, edit in
                                        ipairs(
                                            presentation.additionalTextEdits
                                                or {}
                                        )
                                    do
                                        edits[#edits + 1] = edit
                                    end
                                    applied, reason = apply_lsp_edit(
                                        bufnr,
                                        edits,
                                        presentation_result.encoding
                                    )
                                end
                                presentation_result.applied = applied
                                presentation_result.presentation = presentation
                                presentation_result.reason = applied and nil
                                    or reason
                                if applied then
                                    notify_user(
                                        notify,
                                        ("Applied Typst color presentation: %s"):format(
                                            presentation.label
                                                or "<presentation>"
                                        )
                                    )
                                else
                                    presentation_result.ok = false
                                    presentation_result.message =
                                        "Tinymist color presentation did not include an applicable edit"
                                end
                            elseif selected ~= nil then
                                presentation_result.ok = false
                                presentation_result.reason =
                                    "missing_presentation"
                                presentation_result.message = ("No Tinymist color presentation matching %s"):format(
                                    tostring(selected)
                                )
                            elseif opts.open ~= false then
                                presentation_result.buffer = open_lines(
                                    "typst.nvim color presentations",
                                    "typstsemantic",
                                    report_presentation_lines(presentations),
                                    opts
                                )
                            end

                            presentation_result.count = #presentations
                            opts.callback(presentation_result)
                        end,
                    })
                )
            end,
        })
    )
end

--- Request Typst document links and render a report buffer.
---@param project table Project state used for provider fallback context.
---@param opts? table Document-link options; `callback` enables Tinymist requests.
---@return table|nil result Provider result, pending request, or failure payload.
function M.document_links(project, opts)
    opts = opts or {}
    local provider_result = provider_run("document_links", project, opts)
    if provider_result ~= nil then
        return provider_result
    end

    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local function build_result(links)
        links = links or {}
        local lines = { "typst.nvim document links" }
        for _, link in ipairs(links) do
            local range = link.range or {}
            local start = range.start or {}
            lines[#lines + 1] = ("%d:%d %s"):format(
                (start.line or 0) + 1,
                (start.character or 0) + 1,
                link.target or "<unresolved>"
            )
        end

        return {
            ok = true,
            links = links,
            count = #links,
            buffer = open_lines(
                "typst.nvim document links",
                "typstsemantic",
                lines,
                opts
            ),
        }
    end

    if type(opts.callback) == "function" then
        return tinymist.document_links(
            bufnr,
            vim.tbl_extend("force", opts, {
                guard_cursor = false,
                callback = function(result)
                    if not result.ok then
                        opts.callback(result)
                        return
                    end
                    opts.callback(build_result(result.links or {}))
                end,
            })
        )
    end

    return async_required("textDocument/documentLink")
end

--- Request or execute Typst code lenses.
---@param project table Project state used for provider fallback context.
---@param opts? table Code-lens options; `execute`/`index` runs one lens.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|nil result Provider result, pending request, or failure payload.
function M.code_lens(project, opts, notify)
    opts = opts or {}
    local provider_result = provider_run("code_lens", project, opts)
    if provider_result ~= nil then
        return provider_result
    end

    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local function build_result(lenses)
        lenses = lenses or {}
        if opts.execute or opts.index then
            -- Code lens requests can either report available lenses or execute
            -- one selected lens. Keep both behind the same request so the list
            -- and command come from the same server response.
            local lens = lenses[tonumber(opts.execute or opts.index) or 1]
            if lens and lens.command then
                tinymist.execute_command(lens.command, nil, {
                    bufnr = bufnr,
                    source_method = "textDocument/codeLens",
                })
            end
        end

        if vim.lsp.codelens then
            local refresh_ok, refresh_err
            if type(vim.lsp.codelens.enable) == "function" then
                refresh_ok, refresh_err =
                    pcall(vim.lsp.codelens.enable, true, { bufnr = bufnr })
            else
                refresh_ok = false
                refresh_err = "code lens enable is unavailable"
            end
            local lines = { "typst.nvim code lenses" }
            for _, lens in ipairs(lenses) do
                local command = lens.command or {}
                local range = lens.range or {}
                local start = range.start or {}
                lines[#lines + 1] = ("%d:%d %s"):format(
                    (start.line or 0) + 1,
                    (start.character or 0) + 1,
                    command.title or command.command or "<code lens>"
                )
            end
            notify_user(notify, "Typst code lenses refreshed")
            return {
                ok = true,
                bufnr = bufnr,
                refreshed = refresh_ok,
                refresh_error = refresh_ok and nil or refresh_err,
                lenses = lenses,
                count = #lenses,
                buffer = open_lines(
                    "typst.nvim code lenses",
                    "typstsemantic",
                    lines,
                    opts
                ),
            }
        end

        return {
            ok = false,
            reason = "unsupported",
            message = "Neovim code lenses are unavailable",
        }
    end

    if type(opts.callback) == "function" then
        return tinymist.code_lens(
            bufnr,
            vim.tbl_extend("force", opts, {
                guard_cursor = false,
                callback = function(result)
                    if not result.ok then
                        opts.callback(result)
                        return
                    end
                    opts.callback(build_result(result.lenses or {}))
                end,
            })
        )
    end

    return async_required("textDocument/codeLens")
end

--- Request Typst workspace symbols and render a report buffer.
---@param project table Project state used to find an attached Tinymist client.
---@param opts? table Workspace-symbol options; `callback` enables Tinymist requests.
---@return table|nil result Provider result, pending request, or failure payload.
function M.workspace_symbols(project, opts)
    opts = opts or {}
    local provider_result = provider_run("workspace_symbols", project, opts)
    if provider_result ~= nil then
        return provider_result
    end

    if type(opts.callback) == "function" then
        return tinymist.workspace_symbols(
            project,
            vim.tbl_extend("force", opts, {
                callback = function(result)
                    local symbols = result.symbols or {}
                    local lines = { "typst.nvim workspace symbols" }
                    for _, symbol in ipairs(symbols) do
                        lines[#lines + 1] = ("%s  %s:%d:%d"):format(
                            symbol.name or "<symbol>",
                            symbol.file
                                    and util.relpath(symbol.file, project.root)
                                or project.main,
                            symbol.lnum or 1,
                            symbol.col or 1
                        )
                    end
                    result.symbols = symbols
                    result.count = #symbols
                    result.buffer = open_lines(
                        "typst.nvim workspace symbols",
                        "typstsemantic",
                        lines,
                        opts
                    )
                    opts.callback(result)
                end,
            })
        )
    end

    return async_required("workspace/symbol")
end

--- Request Typst references and render a report buffer.
---@param project table Project state used for report path display.
---@param opts? table Reference options; `callback` enables Tinymist requests.
---@return table|nil result Provider result, pending request, or failure payload.
function M.references(project, opts)
    opts = opts or {}
    local provider_result = provider_run("references", project, opts)
    if provider_result ~= nil then
        return provider_result
    end

    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if type(opts.callback) == "function" then
        return tinymist.references(
            bufnr,
            vim.tbl_extend("force", opts, {
                callback = function(result)
                    local references = result.references or {}
                    local lines = { "typst.nvim references" }
                    for _, reference in ipairs(references) do
                        lines[#lines + 1] = ("%s:%d:%d"):format(
                            reference.file
                                    and util.relpath(
                                        reference.file,
                                        project.root
                                    )
                                or project.main,
                            reference.lnum or 1,
                            reference.col or 1
                        )
                    end
                    result.references = references
                    result.count = #references
                    result.buffer = open_lines(
                        "typst.nvim references",
                        "typstsemantic",
                        lines,
                        opts
                    )
                    opts.callback(result)
                end,
            })
        )
    end

    return async_required("textDocument/references")
end

--- Request a Tinymist rename without applying edits and open the edit preview.
---@param project table Project state used for provider fallback context.
---@param opts? table Rename options; requires `new_name`/`name` and callback.
---@return table|nil result Provider result, pending request, or failure payload.
function M.rename_preview(project, opts)
    opts = opts or {}
    local provider_result = provider_run("rename_preview", project, opts)
    if provider_result ~= nil then
        return provider_result
    end

    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    local new_name = opts.new_name or opts.name
    if not new_name or new_name == "" then
        return {
            ok = false,
            reason = "empty_name",
            message = "No rename target was provided",
        }
    end

    if type(opts.callback) == "function" then
        return tinymist.rename(
            bufnr,
            new_name,
            vim.tbl_extend("force", opts, {
                apply = false,
                callback = function(result)
                    if result.ok and opts.open ~= false then
                        local lines = {
                            "typst.nvim rename preview",
                            ("  new name: %s"):format(new_name),
                            ("  client: %s"):format(
                                result.client or "tinymist"
                            ),
                            "",
                            vim.inspect(result.edit),
                        }
                        result.buffer = reports.open_scratch_buffer(
                            "typst.nvim rename preview",
                            "typstsemantic",
                            lines
                        )
                    end
                    opts.callback(result)
                end,
            })
        )
    end

    local result = tinymist.rename(
        bufnr,
        new_name,
        vim.tbl_extend("force", opts, { apply = false })
    )
    if type(result) ~= "table" then
        return {
            ok = false,
            reason = "rename_unavailable",
            provider = "tinymist",
            message = "Tinymist rename did not return a result",
        }
    end
    if result.ok and opts.open ~= false then
        local lines = {
            "typst.nvim rename preview",
            ("  new name: %s"):format(new_name),
            ("  client: %s"):format(result.client or "tinymist"),
            "",
            vim.inspect(result.edit),
        }
        result.buffer = reports.open_scratch_buffer(
            "typst.nvim rename preview",
            "typstsemantic",
            lines
        )
    end
    return result
end

--- Request LSP selection ranges for the current cursor position.
---@param _? table Project argument kept for API symmetry.
---@param opts? table Selection-range options; `callback` enables Tinymist requests.
---@return table|nil result Pending request or failure payload.
function M.selection_expand(_, opts)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if type(opts.callback) == "function" then
        return tinymist.selection_range(bufnr, opts)
    end

    return async_required("textDocument/selectionRange")
end

--- Request Tinymist's experimental on-enter edits and apply them explicitly.
---@param _? table Project argument kept for API symmetry.
---@param opts? table On-enter options; `callback` enables Tinymist requests.
---@param notify? fun(message:string, level?:vim.log.levels|integer) Notification sink.
---@return table|nil result Pending request or failure payload.
function M.on_enter(_, opts, notify)
    opts = opts or {}
    local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
    if type(opts.callback) ~= "function" then
        return async_required("experimental/onEnter")
    end

    return tinymist.on_enter(
        bufnr,
        vim.tbl_extend("force", opts, {
            guard_changedtick = opts.guard_changedtick ~= false,
            callback = function(result)
                if result.ok and opts.apply ~= false then
                    local applied, reason =
                        apply_lsp_edit(bufnr, result.edits, result.encoding)
                    result.applied = applied
                    result.reason = applied and result.reason or reason
                    if applied then
                        notify_user(notify, "Applied Typst on-enter edits")
                    else
                        result.ok = false
                        result.message =
                            "Tinymist on-enter did not include an applicable edit"
                    end
                end
                opts.callback(result)
            end,
        })
    )
end

return M
